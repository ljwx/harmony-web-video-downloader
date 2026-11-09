import { webview } from '@kit.ArkWeb';
import { url } from '@kit.ArkTS';
import { MediaKind, MediaCandidate, PageContext, HeaderProvider } from './Contracts';
import { VIDEO_SCRIPT } from './PageScript';

export interface CandidateClassifier { classify(value: string, mime?: string, disposition?: string): MediaCandidate; }
export class DefaultClassifier implements CandidateClassifier {
  classify(value: string, mime: string = '', disposition: string = ''): MediaCandidate {
    let path = value.split(/[?#]/)[0].toLowerCase();
    let type = mime.split(';')[0].trim().toLowerCase();
    let kind = MediaKind.Unknown;
    if (/^blob:/i.test(value)) kind = MediaKind.Blob;
    else if (/\.m3u8$/.test(path) || /application\/(vnd.apple.mpegurl|x-mpegurl)/.test(type)) kind = MediaKind.Hls;
    else if (/\.mpd$/.test(path) || type === 'application/dash+xml') kind = MediaKind.Dash;
    else if (/\.(mp4|m4v|webm|mov|3gp|vdat)$/.test(path) || type.startsWith('video/') ||
      /\.(mp4|m4v|webm|mov|3gp)/i.test(disposition) ||
      /\/video\/tos\/|mime_type=video_|video_id=|douyinvod.com|ibytedtos.com/i.test(value)) kind = MediaKind.Direct;
    return { url: value, kind: kind, mime: type };
  }
}
interface ExtractedSources { urls: string[]; activeUrl: string; }
export class MediaDiscovery {
  private seen: Map<string, MediaCandidate> = new Map();
  private generation: number = 0;
  private classifier: CandidateClassifier;
  constructor(classifier: CandidateClassifier = new DefaultClassifier()) { this.classifier = classifier; }
  reset(): void { this.generation++; this.seen.clear(); }
  observe(value: string, mime: string = '', disposition: string = ''): void {
    if (!/^(https?:\/\/|blob:)/i.test(value)) return;
    const candidate = this.classifier.classify(value, mime, disposition);
    if (candidate.kind !== MediaKind.Unknown) this.seen.set(value, candidate);
  }
  async scan(controller: webview.WebviewController): Promise<void> {
    const generation = this.generation;
    let raw = await controller.runJavaScript(VIDEO_SCRIPT);
    // ArkWeb can return either a JSON string or an encoded JS string result.
    if (raw.startsWith('"')) raw = JSON.parse(raw) as string;
    const sources = JSON.parse(raw) as ExtractedSources;
    if (generation !== this.generation) return;
    sources.urls.forEach((value: string) => this.observe(value));
    if (sources.activeUrl) this.observe(sources.activeUrl);
  }
  candidates(): MediaCandidate[] { return Array.from(this.seen.values()); }
}
export class ArkWebHeaders implements HeaderProvider {
  async headers(target: string, page: PageContext): Promise<Record<string, string>> {
    const parsed = new url.URL(target);
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') throw new Error('仅支持 HTTP(S)');
    const headers: Record<string, string> = { 'Accept': '*/*', 'User-Agent': page.userAgent };
    // Origin-only cross-origin referrer avoids leaking page query parameters.
    const origin = new url.URL(page.url);
    headers['Referer'] = origin.origin === parsed.origin ? page.url : `${origin.origin}/`;
    const cookie = await webview.WebCookieManager.fetchCookie(target);
    if (cookie) headers['Cookie'] = cookie;
    return headers;
  }
}
