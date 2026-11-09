import { DownloadTaskRow } from './DownloadTaskRow';
import { extractPageAddress, canonicalVideoPage } from '../webvideo/PageAddress';
import { webview } from '@kit.ArkWeb';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { DownloadManager, MediaDiscovery, MediaCandidate, TaskSnapshot } from '../webvideo/Index';

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private player: VideoController = new VideoController();
  @State private playback: string = '';
  private discovery: MediaDiscovery = new MediaDiscovery();
  private manager?: DownloadManager;
  private unsubscribe?: () => void;
  private timer: number = -1;
  private pageUrl: string = 'https://www.douyin.com/';
  private pageVersion: number = 0;
  private pageLoadFailed: boolean = false;
  private scanPending: boolean = false;
  @State private address: string = 'https://www.douyin.com/';
  @State private candidates: MediaCandidate[] = [];
  @State private tasks: TaskSnapshot[] = [];
  @State private message: string = '打开网页并播放视频，然后点击识别';
  @State private metered: boolean = false;
  @State private showDownloads: boolean = false;
  aboutToAppear(): void {
    this.manager = new DownloadManager(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.unsubscribe = this.manager.subscribe((tasks: TaskSnapshot[]) => { this.tasks = tasks; });
  }
  aboutToDisappear(): void { this.unsubscribe?.(); this.stopScan(); }
  private stopScan(): void { if (this.timer >= 0) clearInterval(this.timer); this.timer = -1; }
  private report(error: Error): void { this.message = error.message; }
  private async scan(): Promise<void> {
    if (this.scanPending) return;
    this.scanPending = true;
    try { await this.discovery.scan(this.controller); this.candidates = this.discovery.candidates(); }
    catch (error) { console.warn(`视频识别失败：${(error as Error).message}`); }
    finally { this.scanPending = false; }
  }
  private open(): void {
    const extracted = extractPageAddress(this.address);
    const target = canonicalVideoPage(extracted) || extracted;
    if (!target) { this.message = '未找到有效链接，请输入网页链接或粘贴完整分享文案'; return; }
    this.address = target;
    this.message = '正在打开网页…';
    this.pageLoadFailed = false;
    try { this.controller.loadUrl(target); } catch (error) { this.report(error as Error); }
  }
  private redirectSharePage(value: string): boolean {
    const target = canonicalVideoPage(value);
    if (!target) return false;
    const version = this.pageVersion;
    this.stopScan();
    this.message = '正在打开视频网页…';
    // ArkWeb interception callbacks must finish before starting another navigation.
    setTimeout(() => {
      if (version !== this.pageVersion) return;
      this.address = target;
      try { this.controller.loadUrl(target); } catch (error) { this.report(error as Error); }
    }, 0);
    return true;
  }
  private removeTask(task: TaskSnapshot): void {
    this.getUIContext().showAlertDialog({ title: '删除下载', message: '删除该任务及其已下载文件？',
      primaryButton: { value: '保留', action: () => {} },
      secondaryButton: { value: '删除', action: () => {
        if (task.result && this.playback === fileUri.getUriFromPath(task.result.path)) {
          this.player.stop(); this.playback = '';
        }
        this.manager?.remove(task.id).catch((e: Error) => this.report(e));
      } } });
  }
  private download(candidate: MediaCandidate): void {
    try {
      this.manager?.start(candidate, { url: this.pageUrl, title: this.controller.getTitle(),
        userAgent: this.controller.getUserAgent() }, {
        network: { metered: this.metered, roaming: false, background: false }
      });
      this.message = '任务已创建；默认仅 Wi-Fi，允许移动网络需先开启开关';
      this.showDownloads = true;
    } catch (error) { this.report(error as Error); }
  }
  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.address, placeholder: '输入网页地址' })
          .onChange((value: string) => { this.address = value; }).layoutWeight(1)
        Button('打开').onClick(() => this.open())
      }.padding({ left: 12, right: 12 })
      Row({ space: 8 }) {
        Button('识别').onClick(() => { this.scan(); })
        Button(this.showDownloads ? '视频列表' : `任务 (${this.tasks.length})`)
          .onClick(() => { this.showDownloads = !this.showDownloads; })
        Text('移动网络').fontSize(12)
        Toggle({ type: ToggleType.Switch, isOn: this.metered }).onChange((value: boolean) => { this.metered = value; })
      }
      Text(this.message).fontSize(12).maxLines(2).padding({ left: 12, right: 12 })
      Web({ src: 'https://www.douyin.com/', controller: this.controller })
        .javaScriptAccess(true).domStorageAccess(true)
        .onPageBegin((event) => {
          this.pageVersion++; this.stopScan(); this.discovery.reset(); this.candidates = [];
          this.pageLoadFailed = false; this.message = '正在加载网页…';
          if (event) { this.pageUrl = event.url; this.address = event.url; }
        })
        .onPageEnd((event) => {
          if (event) { this.pageUrl = event.url; this.address = event.url; }
          if (this.pageLoadFailed) return;
          if (event && this.redirectSharePage(event.url)) return;
          this.message = '网页已加载，播放视频后点击识别';
          this.scan(); this.stopScan();
          this.timer = setInterval(() => { this.scan(); }, 2500);
        })
        .onErrorReceive((event) => {
          if (event?.request.isMainFrame()) {
            this.pageLoadFailed = true; this.stopScan();
            this.message = `网页加载失败：${event.error.getErrorInfo()}（${event.error.getErrorCode()}）`;
          }
        })
        .onHttpErrorReceive((event) => {
          if (event?.request.isMainFrame()) {
            this.pageLoadFailed = true; this.stopScan();
            this.message = `网页请求失败：HTTP ${event.response.getResponseCode()}`;
          }
        })
        .onLoadIntercept((event) => {
          if (!event) return false;
          if (event.data.isMainFrame() && this.redirectSharePage(event.data.getRequestUrl())) return true;
          const blocked = !/^https?:\/\//i.test(event.data.getRequestUrl());
          if (blocked && event.data.isMainFrame()) this.message = '已阻止跳转外部应用，请在网页内播放视频';
          return blocked;
        })
        .onInterceptRequest((event) => {
          if (event) {
            const resource = event.request.getRequestUrl();
            const version = this.pageVersion;
            setTimeout(() => {
              if (version !== this.pageVersion) return;
              this.discovery.observe(resource); this.candidates = this.discovery.candidates();
            }, 0);
          }
          return null;
        })
        .onDownloadStart((event) => {
          if (event) {
            this.discovery.observe(event.url, event.mimetype, event.contentDisposition);
            this.candidates = this.discovery.candidates();
          }
        }).layoutWeight(1).width('100%')
      if (this.playback) {
        Video({ src: this.playback, controller: this.player }).autoPlay(true).controls(true).height('25%')
          .onError(() => { this.message = '系统播放器无法播放该文件或本地 HLS 包'; })
        Button('关闭播放').onClick(() => { this.player.stop(); this.playback = ''; })
      }
      List({ space: 8 }) {
        if (this.showDownloads) {
          ForEach(this.tasks, (task: TaskSnapshot, index: number) => {
            ListItem() {
              DownloadTaskRow({ task: this.tasks[index],
                onPause: (id: string) => { this.manager?.pause(id).catch((e: Error) => this.report(e)); },
                onResume: (id: string) => { this.manager?.resume(id).catch((e: Error) => this.report(e)); },
                onCancel: (id: string) => { this.manager?.cancel(id).catch((e: Error) => this.report(e)); },
                onPlay: (path: string) => { this.playback = fileUri.getUriFromPath(path); },
                onRemove: (value: TaskSnapshot) => this.removeTask(value)
              })
            }
          }, (task: TaskSnapshot) => task.id)
        } else {
          ForEach(this.candidates, (candidate: MediaCandidate) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(`[${candidate.kind}] ${candidate.url}`).fontSize(12).maxLines(2).layoutWeight(1)
                Button('下载').onClick(() => this.download(candidate))
              }
            }
          }, (candidate: MediaCandidate) => candidate.url)
        }
      }.height('28%').padding(12)
    }.padding({ top: 8, bottom: 8 }).height('100%').width('100%')
  }
}
