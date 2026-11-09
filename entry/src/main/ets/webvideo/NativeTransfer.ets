import { common } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DownloadError, NetworkPolicy } from './Contracts';

// One native system download at a time. Keeps control intent while asynchronous creation is in flight.
export class NativeTransfer {
  private task?: request.DownloadTask;
  private paused: boolean = false;
  private cancelled: boolean = false;
  private releaseGate?: () => void;
  private rejectCurrent?: (error: Error) => void;
  private context: common.UIAbilityContext;
  private policy: NetworkPolicy;
  constructor(context: common.UIAbilityContext, policy: NetworkPolicy) { this.context = context; this.policy = policy; }
  async pause(): Promise<void> { this.paused = true; if (this.task) await this.task.pause(); }
  async resume(): Promise<void> { this.paused = false; this.releaseGate?.(); this.releaseGate = undefined; if (this.task) await this.task.resume(); }
  async cancel(): Promise<void> {
    this.cancelled = true;
    this.releaseGate?.(); this.releaseGate = undefined;
    this.rejectCurrent?.(new DownloadError('CANCELLED', '下载已取消'));
    if (this.task) await this.task.delete();
  }
  async download(source: string, destination: string, headers: Record<string, string>,
    progress: (received: number, total: number) => void): Promise<number> {
    if (this.paused) await new Promise<void>((resolve) => { this.releaseGate = resolve; });
    if (this.cancelled) throw new DownloadError('CANCELLED', '下载已取消');
    const temporary = `${destination}.part`;
    if (fs.accessSync(temporary)) fs.unlinkSync(temporary);
    const task = await request.downloadFile(this.context, {
      url: source, filePath: temporary, header: headers,
      enableMetered: this.policy.metered, enableRoaming: this.policy.roaming,
      background: this.policy.background, title: '网页视频下载'
    });
    this.task = task;
    try {
      if (this.cancelled) { await task.delete(); throw new DownloadError('CANCELLED', '下载已取消'); }
      await new Promise<void>((resolve, reject) => {
        let settled = false;
        const complete = (): void => { if (!settled) { settled = true; resolve(); } };
        const fail = (error: Error): void => { if (!settled) { settled = true; reject(error); } };
        this.rejectCurrent = fail;
        task.on('progress', progress);
        task.on('complete', complete);
        task.on('fail', (code: number) => fail(new DownloadError(`HTTP_DOWNLOAD_${code}`, '系统下载失败')));
        // Query covers a small file completing before listeners were installed.
        task.query().then((info: request.DownloadInfo) => {
          if (info.status === request.SESSION_SUCCESSFUL) complete();
          else if (info.status === request.SESSION_FAILED) fail(new DownloadError('HTTP_DOWNLOAD', '系统下载失败'));
        }).catch((error: Error) => fail(error));
        if (this.paused) task.pause().catch((error: Error) => fail(error));
      });
      const bytes = fs.statSync(temporary).size;
      if (bytes <= 0) throw new DownloadError('EMPTY_FILE', '下载内容为空');
      fs.renameSync(temporary, destination);
      return bytes;
    } finally {
      task.off('progress'); task.off('complete'); task.off('fail');
      this.task = undefined; this.rejectCurrent = undefined;
    }
  }
}
