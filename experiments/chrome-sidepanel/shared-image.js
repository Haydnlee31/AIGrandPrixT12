/** Resize only the outgoing copy; the local original remains in IndexedDB. */
export function imageBytes(data) {
  if (!/^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/]+=*$/.test(data || '')) throw new Error('Choose a PNG, JPEG or WebP image.');
  const encoded = data.split(',')[1];
  return encoded.length * 3 / 4 - (encoded.endsWith('==') ? 2 : encoded.endsWith('=') ? 1 : 0);
}

export async function sharedImage(data, limit) {
  const maxBytes = Math.min(Number.isSafeInteger(limit) && limit > 0 ? limit : 3145728, 3145728);
  if (imageBytes(data) <= maxBytes) return data;
  const raw = Uint8Array.from(atob(data.split(',')[1]), char => char.charCodeAt(0));
  const bitmap = await createImageBitmap(new Blob([raw], {type: data.slice(5, data.indexOf(';'))}));
  try {
    for (const edge of [2048, 1280, 800]) {
      const scale = Math.min(1, edge / Math.max(bitmap.width, bitmap.height));
      const canvas = new OffscreenCanvas(Math.max(1, Math.round(bitmap.width * scale)), Math.max(1, Math.round(bitmap.height * scale)));
      const context = canvas.getContext('2d');
      context.fillStyle = '#fff'; context.fillRect(0, 0, canvas.width, canvas.height);
      context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      const blob = await canvas.convertToBlob({type: 'image/jpeg', quality: .8});
      if (blob.size > maxBytes) continue;
      const bytes = new Uint8Array(await blob.arrayBuffer());
      let binary = '';
      for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
      return 'data:image/jpeg;base64,' + btoa(binary);
    }
    throw new Error('This image is too large for the shared library. Your local original is safe.');
  } finally { bitmap.close(); }
}
