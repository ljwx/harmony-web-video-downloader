export enum MediaKind { Direct = 'direct', Hls = 'hls', Dash = 'dash', Blob = 'blob', Unknown = 'unknown' }
export enum TaskState {
  Preparing = 'preparing', Downloading = 'downloading', Paused = 'paused',
  Completed = 'completed', Failed = 'failed', Cancelled = 'cancelled'
}
export interface MediaCandidate { url: string; kind: MediaKind; mime?: string; }
export interface PageContext { url: string; title: string; userAgent: string; }
export interface NetworkPolicy { metered: boolean; roaming: boolean; background: boolean; }
export interface DownloadOptions { network: NetworkPolicy; maxVideoHeight?: number; audioLanguage?: string; }
// Called for EACH target URL, including segments/keys. Do not forward a page Cookie to another host.
export interface HeaderProvider { headers(url: string, page: PageContext): Promise<Record<string, string>>; }
export interface DownloadResult { path: string; format: 'file' | 'hls-package'; bytes: number; }
export interface TaskSnapshot {
  id: string; sourceUrl: string; title: string; state: TaskState;
  received: number; total: number; message: string; result?: DownloadResult;
}
export interface ProgressSink { update: (received: number, total: number) => void; }
export interface DownloadJob {
  run(): Promise<DownloadResult>;
  pause(): Promise<void>;
  resume(): Promise<void>;
  cancel(): Promise<void>;
}
export interface EngineRequest {
  candidate: MediaCandidate; page: PageContext; directory: string;
  options: DownloadOptions; headers: HeaderProvider; progress: ProgressSink;
}
export interface DownloadEngine {
  supports(kind: MediaKind): boolean;
  create(request: EngineRequest): DownloadJob;
}
export class DownloadError implements Error {
  name: string = 'DownloadError';
  message: string;
  code: string;
  constructor(code: string, message: string) { this.message = message; this.code = code; }
}
export const DEFAULT_OPTIONS: DownloadOptions = {
  network: { metered: false, roaming: false, background: false }
};
