export const DEFAULT_BASE_URL = 'http://127.0.0.1:8000';

export function normalizeBackendURL(value) {
  let url;
  try { url = new URL(String(value).trim()); } catch { throw new Error('Enter a backend origin such as https://api.example.com.'); }
  const local = ['127.0.0.1', 'localhost'].includes(url.hostname);
  if (url.hostname.includes('*')) throw new Error('Use one backend hostname, without wildcards.');
  if (url.username || url.password || url.search || url.hash || !['', '/'].includes(url.pathname)) {
    throw new Error('Use only the backend origin, without credentials, a path, query, or fragment.');
  }
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && local)) {
    throw new Error('Remote backends require HTTPS. HTTP is allowed only for localhost or 127.0.0.1.');
  }
  return url.origin;
}

export function backendPermission(baseURL) {
  const url = new URL(normalizeBackendURL(baseURL));
  // Include the default port so this pattern is limited to the configured origin.
  return `${url.protocol}//${url.hostname}:${url.port || (url.protocol === 'https:' ? '443' : '80')}/*`;
}

export function sourceFromURL(value) {
  const host = new URL(value).hostname.toLowerCase();
  if (host === 'pinterest.com' || host.endsWith('.pinterest.com')) return 'pinterest';
  if (host === 'instagram.com' || host.endsWith('.instagram.com')) return 'instagram';
  return 'web';
}

export function validatePageURL(value) {
  let url;
  try { url = new URL(value); } catch { throw new Error('Open a public web page to save its link.'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) {
    throw new Error('This page cannot be captured. Open a public HTTP or HTTPS page instead.');
  }
  if (url.href.length > 2048) throw new Error('This page link exceeds the 2,048 character limit.');
  if (!url.hostname.includes('.') || ['127.0.0.1', '0.0.0.0'].includes(url.hostname) || url.hostname.endsWith('.local')) {
    throw new Error('Local and private links are not supported by the capture API.');
  }
  return url.href;
}

export function capturePayload(input) {
  const url = validatePageURL(input.url);
  const title = String(input.title || '').trim();
  if (!title || title.length > 300) throw new Error('Give this save a title between 1 and 300 characters.');
  const selected_text = String(input.selected_text || '');
  const note = String(input.note || '');
  if (selected_text.length > 12000 || note.length > 2000) throw new Error('Selected text or note is too long.');
  return {url, title, selected_text, note, source:sourceFromURL(url), client:'chrome_extension'};
}

export async function requestFingerprint(baseURL, token, payload) {
  // Raw tokens are not stored inside retry metadata or diagnostic messages.
  const bytes = new TextEncoder().encode(JSON.stringify([normalizeBackendURL(baseURL), token, payload]));
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
}

export function readableError(error) {
  if (error?.status === 401) return 'Your workspace token was not accepted. Update it under Workspace access.';
  if (error?.code === 'mutation_expired') return 'This earlier save was invalidated by a deletion. Start a new capture only if you intend to save it again.';
  if (error?.code === 'idempotency_conflict') return 'The server rejected this retry because its content changed. Reopen the popup and review your capture.';
  const message = error?.message || 'The backend could not be reached.';
  return error?.requestId ? `${message} Request ID: ${error.requestId}` : message;
}
