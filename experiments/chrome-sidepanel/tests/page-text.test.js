import test from 'node:test';
import assert from 'node:assert/strict';
import { readPage } from '../capture.js';

test('social extraction reads the caption, not comments or private messages', () => {
  globalThis.location = { hostname: 'www.instagram.com', href: 'https://www.instagram.com/p/Dd1Z-TWs20c/' };
  globalThis.getSelection = () => '';
  globalThis.document = { title: 'Instagram', querySelector(selector) {
    if (selector === 'h1') return { innerText: 'A young swordsman challenged a master. #claymation' };
    if (selector.includes('meta')) return null;
    if (selector === 'article') return { querySelectorAll() { throw new Error('Must not include comment threads'); } };
    return null;
  } };
  const result = readPage();
  assert.equal(result.contentType, 'social');
  assert.match(result.excerpt, /claymation/);
  assert.match(result.textBasis, /not the video/);
});
test('articles include main text, and an explicit selection takes priority', () => {
  globalThis.location = { hostname: 'www.nparks.gov.sg', href: 'https://www.nparks.gov.sg/article' };
  globalThis.getSelection = () => '';
  globalThis.document = { title: 'How Now Brown Bird?', querySelector(selector) {
    if (selector === 'main') return { querySelectorAll: () => [{ innerText: 'Singapore is home to over 400 species of birds.' }] };
    return null;
  } };
  assert.match(readPage().excerpt, /400 species/);
  globalThis.getSelection = () => 'Only this selected paragraph';
  assert.equal(readPage().excerpt, 'Only this selected paragraph');
});
