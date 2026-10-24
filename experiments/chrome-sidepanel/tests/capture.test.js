import test from 'node:test';
import assert from 'node:assert/strict';
import { capturePage, importImage } from '../capture.js';

function browser({ tabs, extractionFails = false } = {}) {
  let reads = 0;
  let screenshots = 0;
  const original = { id: 12, windowId: 2, url: 'https://example.com/room', title: 'Small room' };
  globalThis.chrome = {
    windows: { getCurrent: async () => ({ id: 2 }) },
    tabs: {
      query: async () => [tabs?.[reads++] || original],
      captureVisibleTab: async (windowId) => { assert.equal(windowId, 2); screenshots++; return 'data:image/jpeg;base64,AA=='; }
    },
    scripting: { executeScript: async ({ target }) => {
      assert.equal(target.tabId, 12);
      if (extractionFails) throw new Error('Blocked');
      return [{ result: { url: original.url, title: original.title, excerpt: 'Warm lighting in a small bedroom' } }];
    } }
  };
  return { original, screenshots: () => screenshots };
}

test('page saves retain source text and note without taking a screenshot', async () => {
  const fake = browser();
  const result = await capturePage('page', 'Only lighting');
  assert.equal(result.url, fake.original.url);
  assert.equal(result.note, 'Only lighting');
  assert.equal(result.excerpt, 'Warm lighting in a small bedroom');
  assert.equal(result.image, null);
  assert.equal(fake.screenshots(), 0);
});

test('screenshot records include capture and contextual page text', async () => {
  const fake = browser();
  const result = await capturePage('screenshot', '');
  assert.match(result.image, /^data:image\/jpeg/);
  assert.equal(result.question.id, 'home-v1');
  assert.equal(fake.screenshots(), 1);
});

test('blocked text extraction still permits an honest bookmark', async () => {
  browser({ extractionFails: true });
  const item = await capturePage('page', '');
  assert.equal(item.excerpt, '');
  assert.equal(item.title, 'Small room');
});

test('tab switch prevents saving a screenshot of the wrong page', async () => {
  const original = { id: 12, url: 'https://example.com/room', title: 'Small room' };
  const fake = browser({ tabs: [original, { ...original, id: 19 }] });
  await assert.rejects(capturePage('screenshot', ''), /page changed/);
  assert.equal(fake.screenshots(), 0);
});

test('navigation during capture rejects mismatched evidence', async () => {
  const original = { id: 12, url: 'https://example.com/room', title: 'Small room' };
  browser({ tabs: [original, original, { ...original, url: 'https://example.com/other' }] });
  await assert.rejects(capturePage('screenshot', ''), /page changed/);
});

test('missing activeTab permission gives a recovery instruction', async () => {
  browser({ tabs: [{ id: 12 }] });
  await assert.rejects(capturePage('page', ''), /toolbar icon/);
});

test('image boundary rejects unsupported or oversized uploads', async () => {
  await assert.rejects(importImage({ type: 'image/svg+xml', size: 40 }, ''), /PNG, JPEG or WebP/);
  await assert.rejects(importImage({ type: 'image/png', size: 9 * 1024 * 1024 }, ''), /smaller than 8 MB/);
});
