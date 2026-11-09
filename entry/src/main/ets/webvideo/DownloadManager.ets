import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { DownloadEngine, DownloadJob, TaskSnapshot, TaskState, MediaCandidate, MediaKind,
  PageContext, DownloadOptions, DEFAULT_OPTIONS, HeaderProvider, DownloadError, ProgressSink, EngineRequest } from './Contracts';
import { ArkWebHeaders } from './MediaDiscovery';
import { DirectEngine, HlsEngine } from './NativeEngines';
export type TaskListener = (tasks: TaskSnapshot[]) => void;
interface TaskEntry { snapshot: TaskSnapshot; job?: DownloadJob; directory: string; settled?: Promise<void>; }
// Ability-scoped owner; Web page transitions only reset discovery, never these tasks.
export class DownloadManager {
  private entries: Map<string, TaskEntry> = new Map();
  private listeners: Set<TaskListener> = new Set();
  private engines: DownloadEngine[];
  private context: common.UIAbilityContext;
  private headers: HeaderProvider;
  constructor(context: common.UIAbilityContext, engines?: DownloadEngine[],
    headers: HeaderProvider = new ArkWebHeaders()) {
    this.context = context; this.headers = headers;
    this.engines = engines || [new DirectEngine(context), new HlsEngine(context)];
    this.restoreCompleted();
  }
  subscribe(listener: TaskListener): () => void {
    this.listeners.add(listener); listener(this.list());
    return (): void => { this.listeners.delete(listener); };
  }
  list(): TaskSnapshot[] { return Array.from(this.entries.values()).map((entry: TaskEntry) => this.copy(entry.snapshot)); }
  start(candidate: MediaCandidate, page: PageContext, options: DownloadOptions = DEFAULT_OPTIONS): string {
    if (!/^https?:\/\//i.test(candidate.url)) {
      throw new DownloadError('UNSUPPORTED_SOURCE', 'blob 不是可下载文件，请选择识别到的真实网络视频地址');
    }
    const engine = this.engines.find((value: DownloadEngine) => value.supports(candidate.kind));
    if (!engine) throw new DownloadError('ENGINE_UNAVAILABLE', '此格式尚未配置下载引擎（DASH 需要额外实现）');
    const existing = Array.from(this.entries.values()).find((entry: TaskEntry) =>
      entry.snapshot.sourceUrl === candidate.url && entry.snapshot.state !== TaskState.Cancelled && entry.snapshot.state !== TaskState.Failed);
    if (existing) {
      if (existing.snapshot.state === TaskState.Paused) throw new DownloadError('TASK_PAUSED', '该视频已有暂停任务，请恢复任务');
      return existing.snapshot.id;
    }
    const id = util.generateRandomUUID(true);
    const directory = `${this.context.filesDir}/webvideo/${id}`;
    fs.mkdirSync(directory, true);
    const snapshot: TaskSnapshot = { id: id, sourceUrl: candidate.url, title: page.title || '网页视频',
      state: TaskState.Preparing, received: 0, total: 0, message: '' };
    const progress: ProgressSink = { update: (received: number, total: number): void => {
      snapshot.received = received; snapshot.total = total;
      if (snapshot.state !== TaskState.Paused && snapshot.state !== TaskState.Cancelled) snapshot.state = TaskState.Downloading;
      this.emit();
    } };
    const input: EngineRequest = { candidate: candidate, page: page, directory: directory, options: options,
      headers: this.headers, progress: progress };
    const job = engine.create(input);
    const entry: TaskEntry = { snapshot: snapshot, job: job, directory: directory };
    this.entries.set(id, entry); this.emit();
    entry.settled = job.run().then((result) => {
      if (snapshot.state === TaskState.Cancelled) return;
      snapshot.result = result; snapshot.received = result.bytes; snapshot.total = result.bytes;
      snapshot.state = TaskState.Completed;
      try {
        const file = fs.openSync(`${directory}/completed.json`, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try { fs.writeSync(file.fd, JSON.stringify(snapshot)); } finally { fs.closeSync(file); }
      } catch (error) { snapshot.message = '文件已保存，但完成记录写入失败'; }
      this.emit();
    }).catch((error: Error) => {
      if (snapshot.state !== TaskState.Cancelled) {
        snapshot.state = TaskState.Failed;
        snapshot.message = error instanceof DownloadError ? `${error.code}: ${error.message}` : error.message;
        this.emit();
      }
    });
    return id;
  }
  async pause(id: string): Promise<void> {
    const entry = this.get(id);
    if (entry.snapshot.state !== TaskState.Preparing && entry.snapshot.state !== TaskState.Downloading) return;
    await entry.job?.pause();
    if (entry.snapshot.state !== TaskState.Preparing && entry.snapshot.state !== TaskState.Downloading) return;
    entry.snapshot.state = TaskState.Paused; this.emit();
  }
  async resume(id: string): Promise<void> {
    const entry = this.get(id);
    if (entry.snapshot.state !== TaskState.Paused) return;
    await entry.job?.resume();
    if (entry.snapshot.state === TaskState.Paused) entry.snapshot.state = TaskState.Downloading;
    this.emit();
  }
  async cancel(id: string): Promise<void> {
    const entry = this.get(id);
    if (entry.snapshot.state === TaskState.Completed) return;
    entry.snapshot.state = TaskState.Cancelled; this.emit();
    await entry.job?.cancel();
  }
  // Call only after the host has confirmed file deletion with its user.
  async remove(id: string): Promise<void> {
    const entry = this.get(id);
    if (entry.snapshot.state !== TaskState.Completed) await this.cancel(id);
    await entry.settled;
    if (fs.accessSync(entry.directory)) {
      for (const name of fs.listFileSync(entry.directory)) fs.unlinkSync(`${entry.directory}/${name}`);
      fs.rmdirSync(entry.directory);
    }
    this.entries.delete(id); this.emit();
  }
  private restoreCompleted(): void {
    const root = `${this.context.filesDir}/webvideo`;
    if (!fs.accessSync(root)) return;
    for (const id of fs.listFileSync(root)) {
      const directory = `${root}/${id}`;
      const path = `${directory}/completed.json`;
      try {
        if (!fs.accessSync(path)) continue;
        const snapshot = JSON.parse(fs.readTextSync(path)) as TaskSnapshot;
        if (snapshot.state === TaskState.Completed && snapshot.result &&
          snapshot.result.path.startsWith(`${directory}/`) && fs.accessSync(snapshot.result.path)) {
          this.entries.set(snapshot.id, { snapshot: snapshot, directory: directory });
        }
      } catch (error) { console.warn('跳过不可读取的下载完成记录'); }
    }
  }
  private get(id: string): TaskEntry {
    const entry = this.entries.get(id);
    if (!entry) throw new DownloadError('TASK_NOT_FOUND', '下载任务不存在');
    return entry;
  }
  private emit(): void { this.listeners.forEach((listener: TaskListener) => listener(this.list())); }
  private copy(value: TaskSnapshot): TaskSnapshot {
    return { id: value.id, sourceUrl: value.sourceUrl, title: value.title, state: value.state,
      received: value.received, total: value.total, message: value.message, result: value.result };
  }
}
