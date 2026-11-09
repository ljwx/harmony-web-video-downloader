import { url } from '@kit.ArkTS';

// Same extraction boundary as Android WebAutoDownloadDomains.extractHttpUrls.
// Pick the first HTTP(S) link from pasted share text; never pass the prose to ArkWeb.
export function extractPageAddress(text: string): string {
  const matches = text.match(/https?:\/\/[^\s<>"'，。；：！？（）【】《》]+/gi) || [];
  for (const match of matches) {
    const candidate = match.replace(/[.,;:!?)\]}。 ，；：！？）】》]+$/, '');
    try {
      const parsed = new url.URL(candidate);
      if ((parsed.protocol === 'http:' || parsed.protocol === 'https:') && parsed.hostname) return candidate;
    } catch (error) {
      // A malformed link must not prevent checking the next link in the share text.
    }
  }
  return '';
}

// Only replace the legacy share-video route seen failing in ArkWeb.
// m.douyin.com is already playable and must not be redirected back into a loop.
export function canonicalVideoPage(value: string): string {
  try {
    const parsed = new url.URL(value);
    const host = parsed.hostname.toLowerCase();
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return '';
    if (host !== 'iesdouyin.com' && !host.endsWith('.iesdouyin.com')) return '';
    const match = /^\/share\/video\/(\d+)\/?$/.exec(parsed.pathname);
    return match ? `https://www.douyin.com/video/${match[1]}` : '';
  } catch (error) { return ''; }
}
