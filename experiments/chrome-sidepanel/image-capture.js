import { createSave, safeUrl } from './questions.js';

// Runs only after the user chooses our image context menu.
export function readImage(srcUrl) {
  const images = [...document.images].filter(img => img.currentSrc === srcUrl || img.src === srcUrl);
  const visible = img => { const r = img.getBoundingClientRect(); return r.width > 0 && r.height > 0 && r.right > 0 && r.bottom > 0 && r.left < innerWidth && r.top < innerHeight; };
  const img = images.find(visible) || images[0];
  if (!img || !img.complete || !img.naturalWidth) throw new Error('This image is no longer available. Right-click it again after it loads.');
  const r = img.getBoundingClientRect();
  const rect = { x: r.x, y: r.y, width: r.width, height: r.height, viewportWidth: innerWidth, viewportHeight: innerHeight };
  const caption = img.closest('figure')?.querySelector('figcaption')?.innerText || '';
  const title = img.alt?.trim() || caption.trim() || `Image from ${document.title}`;
  let image = null;
  try {
    const scale = Math.min(1, 2048 / Math.max(img.naturalWidth, img.naturalHeight));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(img.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(img.naturalHeight * scale));
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#ffffff'; ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    image = canvas.toDataURL('image/jpeg', .85);
  } catch { /* Cross-origin images may taint the canvas. Capture their visible pixels instead. */ }
  return { url: location.href, title, excerpt: [img.alt, caption].filter(Boolean).join('\n').slice(0, 6000), image, rect };
}

export function cropBounds(rect, width, height) {
  if (![rect.x, rect.y, rect.width, rect.height, rect.viewportWidth, rect.viewportHeight, width, height].every(Number.isFinite) || rect.viewportWidth <= 0 || rect.viewportHeight <= 0 || rect.width <= 0 || rect.height <= 0 || width <= 0 || height <= 0) throw new Error('Could not locate this image. Try uploading it instead.');
  const left = Math.max(0, rect.x), top = Math.max(0, rect.y);
  const right = Math.min(rect.viewportWidth, rect.x + rect.width), bottom = Math.min(rect.viewportHeight, rect.y + rect.height);
  if (right <= left || bottom <= top) throw new Error('Bring the image into view, then right-click it again.');
  const sx = width / rect.viewportWidth, sy = height / rect.viewportHeight;
  return { x: Math.round(left * sx), y: Math.round(top * sy), width: Math.max(1, Math.round((right - left) * sx)), height: Math.max(1, Math.round((bottom - top) * sy)) };
}

export async function cropImage(data, rect) {
  const bytes = Uint8Array.from(atob(data.split(',')[1]), char => char.charCodeAt(0));
  const bitmap = await createImageBitmap(new Blob([bytes], { type: 'image/jpeg' }));
  try {
    const box = cropBounds(rect, bitmap.width, bitmap.height);
    const scale = Math.min(1, 2048 / Math.max(box.width, box.height));
    const canvas = new OffscreenCanvas(Math.max(1, Math.round(box.width * scale)), Math.max(1, Math.round(box.height * scale)));
    canvas.getContext('2d').drawImage(bitmap, box.x, box.y, box.width, box.height, 0, 0, canvas.width, canvas.height);
    const blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: .85 });
    const output = new Uint8Array(await blob.arrayBuffer());
    let binary = '';
    for (let i = 0; i < output.length; i += 8192) binary += String.fromCharCode(...output.subarray(i, i + 8192));
    return `data:image/jpeg;base64,${btoa(binary)}`;
  } finally { bitmap.close(); }
}

export async function captureSelectedImage(info, tab) {
  if (!tab?.id || !safeUrl(info.pageUrl || tab.url) || typeof info.srcUrl !== 'string') throw new Error('Right-click an image on a regular website to save it.');
  const target = { tabId: tab.id, frameIds: [info.frameId || 0] };
  const read = async () => {
    const [result] = await chrome.scripting.executeScript({ target, func: readImage, args: [info.srcUrl] });
    if (!result?.result) throw new Error('This site did not allow access to the image. Save a screenshot or upload the image instead.');
    return result.result;
  };
  const assertActive = async () => {
    const [current] = await chrome.tabs.query({ active: true, windowId: tab.windowId });
    if (current?.id !== tab.id || current.url !== tab.url) throw new Error('The page changed while saving. Right-click the image again.');
  };
  // Chrome animates the side panel after open() resolves; let the viewport settle before measuring.
  await new Promise(resolve => setTimeout(resolve, 350));
  await assertActive();
  let source;
  try { source = await read(); }
  catch { throw new Error('Could not read this image. Try opening the image in a new tab, or upload it instead.'); }
  let image = source.image;
  if (!image) {
    // shortcut: protected cross-origin frames cannot be cropped safely; use a manual upload.
    if (info.frameId) throw new Error('This embedded image cannot be copied here. Open the image in a new tab, or upload it instead.');
    await assertActive();
    const screenshot = await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'jpeg', quality: 90 });
    await assertActive();
    const after = await read();
    if (Object.keys(source.rect).some(key => Math.abs(source.rect[key] - after.rect[key]) > 1)) throw new Error('The image moved while saving. Keep it in view and try again.');
    image = await cropImage(screenshot, source.rect);
  }
  await assertActive();
  return createSave({ ...source, url: info.pageUrl || tab.url, kind: 'image', contentType: 'selected-image', imageUrl: info.srcUrl, image, imageCapture: source.image ? 'image' : 'visible-crop', textBasis: 'the image’s alt text or caption, not visual analysis' });
}
