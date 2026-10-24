import { createSave, safeUrl } from './questions.js';

export function readPage() {
  const selection = getSelection()?.toString().trim().slice(0, 6000);
  const social = /(^|\.)(instagram\.com|tiktok\.com)$/.test(location.hostname);
  const description = document.querySelector('meta[property="og:description"]')?.content || document.querySelector('meta[name="description"]')?.content || '';
  // Avoid comments, messages and navigation when saving a social post.
  const caption = social ? document.querySelector('h1')?.innerText || description : '';
  const article = document.querySelector('article') || document.querySelector('main') || document.querySelector('[role="main"]');
  const body = !social && article ? [...article.querySelectorAll('h1, h2, p')].map(el => el.innerText).filter(Boolean).join('\n') : '';
  const excerpt = (selection || (social ? caption : `${description}\n${body}`)).trim().slice(0, 6000);
  return {
    url: location.href, title: social && caption ? caption.slice(0, 160) : document.title,
    excerpt, contentType: social ? 'social' : 'article',
    textBasis: selection ? 'the text you selected' : social ? 'the post caption, not the video or audio' : 'the page title and available article text'
  };
}

export async function capturePage(kind, note) {
  const window = await chrome.windows.getCurrent();
  const [tab] = await chrome.tabs.query({ active: true, windowId: window.id });
  if (!tab?.id || !safeUrl(tab.url)) throw new Error('Open a regular website, then click the Mynah Finds toolbar icon on that tab before saving.');
  let source = { title: tab.title, url: tab.url, excerpt: '' };
  try {
    const [result] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: readPage });
    if (result?.result) source = result.result;
  } catch {
    // Some sites block extraction. The URL/title still form an honest bookmark.
  }
  const stillActive = async () => {
    const [current] = await chrome.tabs.query({ active: true, windowId: window.id });
    if (current?.id !== tab.id || current.url !== source.url) throw new Error('The page changed while saving. Stay on the page and try again.');
  };
  await stillActive();
  const image = kind === 'screenshot' ? await chrome.tabs.captureVisibleTab(window.id, { format: 'jpeg', quality: 75 }) : null;
  await stillActive();
  return createSave({ ...source, kind, image, note });
}

export async function importImage(file, note, contentType = '') {
  if (!file || !['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) throw new Error('Choose a PNG, JPEG or WebP image.');
  if (file.size > 8 * 1024 * 1024) throw new Error('Choose an image smaller than 8 MB.');
  let bitmap;
  try { bitmap = await createImageBitmap(file); }
  catch { throw new Error('That image could not be opened. Try a different screenshot.'); }
  const scale = Math.min(1, 2048 / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(bitmap.width * scale));
  canvas.height = Math.max(1, Math.round(bitmap.height * scale));
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  return createSave({ kind: 'image', contentType, title: file.name, image: canvas.toDataURL('image/jpeg', 0.8), note });
}
