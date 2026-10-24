import test from 'node:test';
import assert from 'node:assert/strict';
import { captureSelectedImage, cropBounds } from '../image-capture.js';

const tab = { id: 3, windowId: 7, url: 'https://example.com/article' };
const info = { pageUrl: tab.url, srcUrl: 'https://cdn.example.com/bird.jpg', frameId: 0 };
const source = { title: 'Common mynah', excerpt: 'A bird in the park', url: tab.url, image: 'data:image/jpeg;base64,AA==', rect: { x: 10, y: 20, width: 80, height: 100, viewportWidth: 400, viewportHeight: 600 } };
function mock({ current = tab, value = source, fail = false } = {}) {
  globalThis.chrome = {
    tabs: { query: async () => [current], captureVisibleTab: async () => { throw new Error('Must not capture the whole page when the image can be copied'); } },
    scripting: { executeScript: async ({ target, args }) => { assert.equal(target.tabId, tab.id); assert.deepEqual(args, [info.srcUrl]); if (fail) throw new Error('Denied'); return [{ result: value }]; } }
  };
}

test('a context save keeps only the selected image plus alt/caption and source', async () => {
  mock();
  const result = await captureSelectedImage(info, tab);
  assert.equal(result.kind, 'image'); assert.equal(result.contentType, 'selected-image');
  assert.equal(result.image, source.image); assert.equal(result.imageCapture, 'image');
  assert.equal(result.url, tab.url); assert.equal(result.imageUrl, info.srcUrl);
  assert.equal(result.question.id, 'birdwatching-v1');
});
test('right-click capture refuses changed tabs and unsafe sources', async () => {
  mock({ current: { ...tab, url: 'https://example.com/elsewhere' } });
  await assert.rejects(captureSelectedImage(info, tab), /page changed/);
  await assert.rejects(captureSelectedImage({ ...info, pageUrl: 'chrome://settings' }, tab), /regular website/);
});
test('inaccessible images give an upload recovery instruction', async () => {
  mock({ fail: true });
  await assert.rejects(captureSelectedImage(info, tab), /upload/);
  mock({ value: { ...source, image: null } });
  await assert.rejects(captureSelectedImage({ ...info, frameId: 8 }, tab), /embedded image/);
});
test('visible-image crop uses screenshot scale and clips to viewport', () => {
  assert.deepEqual(cropBounds(source.rect, 800, 1200), { x: 20, y: 40, width: 160, height: 200 });
  assert.deepEqual(cropBounds({ ...source.rect, x: -20, y: 560 }, 800, 1200), { x: 0, y: 1120, width: 120, height: 80 });
  assert.throws(() => cropBounds({ ...source.rect, x: 401 }, 800, 1200), /into view/);
  assert.throws(() => cropBounds({ ...source.rect, viewportWidth: 0 }, 800, 1200), /locate/);
});
