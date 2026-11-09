import { media } from '@kit.MediaKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { url } from '@kit.ArkTS';
import { DownloadEngine, DownloadJob, DownloadResult, EngineRequest, MediaKind, DownloadError } from './Contracts';
import { NativeTransfer } from './NativeTransfer';

function writeText(path: string, value: string): void {
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try { fs.writeSync(file.fd, value); } finally { fs.closeSync(file); }
}
function resolveUrl(value: string, base: string): string {
  const resolved = new url.URL(value, base);
  if (resolved.protocol !== 'http:' && resolved.protocol !== 'https:') {
    throw new DownloadError('UNSUPPORTED_SCHEME', '分片只支持 HTTP(S)');
  }
  return resolved.href;
}
export class DirectEngine implements DownloadEngine {
  private context: common.UIAbilityContext;
  constructor(context: common.UIAbilityContext) { this.context = context; }
  supports(kind: MediaKind): boolean { return kind === MediaKind.Direct; }
  create(input: EngineRequest): DownloadJob { return new DirectJob(this.context, input); }
}
class DirectJob implements DownloadJob {
  private transfer: NativeTransfer;
  private input: EngineRequest;
  constructor(context: common.UIAbilityContext, input: EngineRequest) {
    this.input = input;
    this.transfer = new NativeTransfer(context, input.options.network);
  }
  async run(): Promise<DownloadResult> {
    const input = this.input;
    const suffix = /\.(mp4|m4v|webm|mov|3gp|vdat)(?:[?#]|$)/i.exec(input.candidate.url)?.[1] || 'mp4';
    const path = `${input.directory}/video.${suffix}`;
    const bytes = await this.transfer.download(input.candidate.url, path,
      await input.headers.headers(input.candidate.url, input.page),
      (received: number, total: number) => input.progress.update(received, total));
    // The native extractor validates a video track; non-empty HTML/JSON is not a successful video.
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    try {
      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: file.fd, offset: 0, length: bytes };
      const metadata = await extractor.fetchMetadata();
      if (Number(metadata.videoWidth) <= 0 || !metadata.videoWidth || Number(metadata.videoHeight) <= 0 || !metadata.videoHeight) {
        throw new DownloadError('INVALID_MEDIA', '文件没有可识别的视频轨道');
      }
    } catch (error) {
      fs.unlinkSync(path);
      throw new DownloadError('INVALID_MEDIA', '下载内容无法由系统识别为视频');
    } finally {
      try { if (extractor) await extractor.release(); } finally { fs.closeSync(file); }
    }
    return { path: path, bytes: bytes, format: 'file' };
  }
  pause(): Promise<void> { return this.transfer.pause(); }
  resume(): Promise<void> { return this.transfer.resume(); }
  cancel(): Promise<void> { return this.transfer.cancel(); }
}
interface Resource { remote: string; local: string; }
interface Manifest { local: string; text: string; }
interface Variant { uri: string; height: number; bandwidth: number; audio: string; }
function attribute(line: string, name: string): string {
  const match = new RegExp(`(?:^|[:,])${name}=(?:"([^"]*)"|([^,]*))`).exec(line);
  return match ? (match[1] || match[2] || '') : '';
}
// Pure parser, exported so alternate transports and fixture tests can reuse the same rules.
export function selectVariant(text: string, maxHeight: number = 0): Variant | undefined {
  const lines = text.split(/\r?\n/).map((line: string) => line.trim());
  const variants: Variant[] = [];
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF:')) continue;
    const uri = lines.slice(i + 1).find((line: string) => line.length > 0 && !line.startsWith('#'));
    if (!uri) throw new DownloadError('INVALID_HLS', '缺少变体地址');
    variants.push({ uri: uri, height: Number(attribute(lines[i], 'RESOLUTION').split('x')[1]) || 0,
      bandwidth: Number(attribute(lines[i], 'BANDWIDTH')) || 0, audio: attribute(lines[i], 'AUDIO') });
  }
  variants.sort((a: Variant, b: Variant) => b.height - a.height || b.bandwidth - a.bandwidth);
  return variants.find((item: Variant) => !maxHeight || item.height <= maxHeight) || variants[variants.length - 1];
}
export class HlsEngine implements DownloadEngine {
  private context: common.UIAbilityContext;
  constructor(context: common.UIAbilityContext) { this.context = context; }
  supports(kind: MediaKind): boolean { return kind === MediaKind.Hls; }
  create(input: EngineRequest): DownloadJob { return new HlsJob(this.context, input); }
}
class HlsJob implements DownloadJob {
  private transfer: NativeTransfer;
  private resources: Resource[] = [];
  private manifests: Manifest[] = [];
  private cancelled: boolean = false;
  private playlistCount: number = 0;
  private input: EngineRequest;
  constructor(context: common.UIAbilityContext, input: EngineRequest) {
    this.input = input;
    this.transfer = new NativeTransfer(context, input.options.network);
  }
  async run(): Promise<DownloadResult> {
    await this.playlist(this.input.candidate.url, 'index.m3u8', 0);
    let bytes = 0;
    for (const resource of this.resources) {
      this.checkCancelled();
      bytes += await this.transfer.download(resource.remote, `${this.input.directory}/${resource.local}`,
        await this.input.headers.headers(resource.remote, this.input.page),
        (received: number, total: number) => this.input.progress.update(bytes + received, 0));
    }
    this.checkCancelled();
    // Publish playlists only after every referenced resource has completed.
    for (const manifest of this.manifests) writeText(`${this.input.directory}/${manifest.local}`, manifest.text);
    return { path: `${this.input.directory}/index.m3u8`, bytes: bytes, format: 'hls-package' };
  }
  private checkCancelled(): void {
    if (this.cancelled) throw new DownloadError('CANCELLED', '下载已取消');
  }
  private async fetch(source: string): Promise<string> {
    this.checkCancelled();
    const path = `${this.input.directory}/manifest_${this.playlistCount++}.source`;
    await this.transfer.download(source, path, await this.input.headers.headers(source, this.input.page),
      (received: number, total: number) => {});
    try {
      if (fs.statSync(path).size > 4 * 1024 * 1024) throw new DownloadError('INVALID_HLS', '播放列表超过 4 MB');
      return fs.readTextSync(path);
    } finally { fs.unlinkSync(path); }
  }

  private resource(remote: string, extension: string): string {
    const existing = this.resources.find((item: Resource) => item.remote === remote);
    if (existing) return existing.local;
    const local = `resource_${this.resources.length}.${extension}`;
    this.resources.push({ remote: remote, local: local });
    return local;
  }
  private async playlist(source: string, local: string, depth: number): Promise<void> {
    if (depth > 4) throw new DownloadError('INVALID_HLS', '播放列表嵌套过深');
    const text = (await this.fetch(source)).trim();
    this.checkCancelled();
    if (!text.startsWith('#EXTM3U')) throw new DownloadError('INVALID_HLS', '不是 HLS 播放列表');
    const variant = selectVariant(text, this.input.options.maxVideoHeight);
    if (variant) {
      const child = `playlist_${this.manifests.length}_${depth}.m3u8`;
      await this.playlist(resolveUrl(variant.uri, source), child, depth + 1);
      let audioTag = '';
      if (variant.audio) {
        const audioLines = text.split(/\r?\n/).filter((line: string) => line.startsWith('#EXT-X-MEDIA:') &&
          attribute(line, 'TYPE') === 'AUDIO' && attribute(line, 'GROUP-ID') === variant.audio);
        const audio = audioLines.find((line: string) => attribute(line, 'LANGUAGE') === this.input.options.audioLanguage) ||
          audioLines.find((line: string) => attribute(line, 'DEFAULT') === 'YES') || audioLines[0];
        if (audio && attribute(audio, 'URI')) {
          const audioLocal = `audio_${depth}.m3u8`;
          await this.playlist(resolveUrl(attribute(audio, 'URI'), source), audioLocal, depth + 1);
          audioTag = `${audio.replace(/URI="[^"]*"/, `URI="${audioLocal}"`)}\n`;
        }
      }
      this.manifests.push({ local: local, text: `#EXTM3U\n${audioTag}#EXT-X-STREAM-INF:BANDWIDTH=${variant.bandwidth || 1}${audioTag ? `,AUDIO="${variant.audio}"` : ''}\n${child}\n` });
      return;
    }
    if (!text.includes('#EXT-X-ENDLIST')) throw new DownloadError('LIVE_UNSUPPORTED', '直播流不支持完整离线下载');
    if (/#EXT-X-(BYTERANGE|PART|PRELOAD-HINT|SKIP)|BYTERANGE=/.test(text)) {
      throw new DownloadError('HLS_RANGE_UNSUPPORTED', '暂不支持字节范围或低延迟 HLS');
    }
    let segments = 0;
    const output = text.split(/\r?\n/).map((raw: string) => {
      const line = raw.trim();
      if (line.startsWith('#EXT-X-KEY:')) {
        const method = attribute(line, 'METHOD');
        if (method === 'NONE') return line;
        if (method !== 'AES-128' || (attribute(line, 'KEYFORMAT') && attribute(line, 'KEYFORMAT') !== 'identity')) {
          throw new DownloadError('DRM_UNSUPPORTED', '不支持 DRM 或 SAMPLE-AES');
        }
      }
      if (line.startsWith('#EXT-X-KEY:') || line.startsWith('#EXT-X-MAP:')) {
        const uri = attribute(line, 'URI');
        if (!uri) throw new DownloadError('INVALID_HLS', '缺少密钥或初始化分片地址');
        const file = this.resource(resolveUrl(uri, source), line.startsWith('#EXT-X-KEY:') ? 'key' : 'mp4');
        return line.replace(/URI="[^"]*"/, `URI="${file}"`);
      }
      if (line && !line.startsWith('#')) { segments++; return this.resource(resolveUrl(line, source), 'seg'); }
      if (line.includes('URI=')) throw new DownloadError('HLS_TAG_UNSUPPORTED', '播放列表包含尚未支持的外部资源');
      return line;
    });
    if (!segments) throw new DownloadError('INVALID_HLS', '没有可下载的视频分片');
    this.manifests.push({ local: local, text: output.join('\n') + '\n' });
  }
  pause(): Promise<void> { return this.transfer.pause(); }
  resume(): Promise<void> { return this.transfer.resume(); }
  async cancel(): Promise<void> { this.cancelled = true; await this.transfer.cancel(); }
}
