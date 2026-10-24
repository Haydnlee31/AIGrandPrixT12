import test from 'node:test';
import assert from 'node:assert/strict';
import {loadSavedLibrary, safeLink, sourceHost, visibleSaves} from '../library.mjs';

function saved(id, overrides = {}) {
  return {
    id,
    title: `Saved ${id}`,
    original_url: `https://example.com/${id}`,
    source: 'web',
    note: '',
    selected_text: '',
    captured_at: 100,
    ...overrides,
  };
}

test('search reaches the final library page and deduplicates shifted page boundaries', async () => {
  const first = saved('first', {title: 'Old title', captured_at: 300});
  const latestFirst = {...first, title: 'Updated reminder'};
  const last = saved('last', {note: 'The recipe from our trip', captured_at: 100});
  const pages = new Map([
    [0, {items: [first, saved('middle', {captured_at: 200})], next_offset: 100}],
    [100, {items: [latestFirst], next_offset: 200}],
    [200, {items: [last], next_offset: null}],
  ]);
  const calls = [];
  const controller = new AbortController();
  const client = {async collection(options) {
    calls.push(options);
    assert.ok(pages.has(options.offset), 'Only follow offsets returned by the server');
    return pages.get(options.offset);
  }};

  const library = await loadSavedLibrary(client, {signal: controller.signal});
  assert.deepEqual(calls.map(call => call.offset), [0, 100, 200]);
  assert.ok(calls.every(call => call.limit === 100 && call.signal === controller.signal));
  assert.equal(library.length, 3);
  assert.equal(library.find(item => item.id === 'first').title, 'Updated reminder');
  assert.deepEqual(visibleSaves(library, {query: 'recipe trip'}).map(item => item.id), ['last']);
  assert.deepEqual(visibleSaves(library).map(item => item.id), ['first', 'middle', 'last']);
});

test('search combines normalized terms across saved title, note, text, source and URL', () => {
  const items = [
    saved('article', {
      title: 'Warm light', source: 'article', note: 'For the reading corner',
      selected_text: 'Try a small shade', original_url: 'https://journal.example.com/quiet-room',
    }),
    saved('pin', {title: 'Warm light', source: 'pinterest', note: 'For the garden'}),
  ];
  const queries = [
    'ＷＡＲＭ　ＬＩＧＨＴ',
    'warm reading',
    'reading shade',
    'articles journal.example.com',
    'quiet-room corner',
  ];
  assert.deepEqual(visibleSaves(items, {query: queries[0]}).map(item => item.id), ['article', 'pin']);
  for (const query of queries.slice(1)) {
    assert.deepEqual(visibleSaves(items, {query}).map(item => item.id), ['article']);
  }
  assert.deepEqual(visibleSaves(items, {query: 'warm garden shade'}), []);
  assert.equal(visibleSaves(items, {query: '  \t  '}).length, 2);
});

test('source filters and sort choices compose without changing the shared library', () => {
  const items = [
    saved('web', {title: 'Cedar', captured_at: 300}),
    saved('older-article', {title: 'Birch', source: 'article', captured_at: 100}),
    saved('newer-article', {title: 'Aspen', source: 'article', captured_at: 200}),
  ];
  const snapshot = structuredClone(items);
  assert.deepEqual(visibleSaves(items, {source: 'article'}).map(item => item.id), ['newer-article', 'older-article']);
  assert.deepEqual(visibleSaves(items, {source: 'article', sort: 'oldest'}).map(item => item.id), ['older-article', 'newer-article']);
  assert.deepEqual(visibleSaves(items, {sort: 'title'}).map(item => item.id), ['newer-article', 'older-article', 'web']);
  assert.deepEqual(visibleSaves(items, {source: 'article', query: 'cedar'}), []);
  assert.deepEqual(visibleSaves(items, {source: 'instagram'}), []);
  assert.deepEqual(items, snapshot);
});

test('original-link navigation refuses executable, local-file and credential-bearing URLs', () => {
  for (const url of [
    'javascript:alert(1)',
    'data:text/html,<script>alert(1)</script>',
    'file:///Users/person/private.txt',
    'https://user:password@example.com/private',
    'https://user@example.com/private',
    '//example.com/relative-origin',
    'not a link',
  ]) {
    assert.equal(safeLink(url), null, url);
  }
  assert.equal(safeLink('https://www.example.com/article?q=light#saved'), 'https://www.example.com/article?q=light#saved');
  assert.equal(safeLink('http://example.com/older-article'), 'http://example.com/older-article');
  assert.equal(sourceHost(saved('one', {original_url: 'https://www.example.com/article'})), 'example.com');
  assert.equal(sourceHost(saved('bad', {original_url: 'not a link'})), 'Saved link');
});

test('a failed later page rejects instead of presenting a partial library as complete', async () => {
  const failure = new Error('Temporary network failure');
  const offsets = [];
  const client = {async collection({offset}) {
    offsets.push(offset);
    if (offset === 0) return {items: [saved('first')], next_offset: 100};
    throw failure;
  }};
  await assert.rejects(loadSavedLibrary(client), error => error === failure);
  assert.deepEqual(offsets, [0, 100]);
});

test('a repeated page cursor stops loading rather than looping indefinitely', async () => {
  const offsets = [];
  const client = {async collection({offset}) {
    offsets.push(offset);
    return {items: [saved(`item-${offset}`)], next_offset: offset === 0 ? 100 : 0};
  }};
  await assert.rejects(loadSavedLibrary(client), /could not finish loading/);
  assert.deepEqual(offsets, [0, 100]);
});

test('an empty library finishes after its first page', async () => {
  let calls = 0;
  const items = await loadSavedLibrary({async collection() {
    calls += 1;
    return {items: [], next_offset: null};
  }});
  assert.deepEqual(items, []);
  assert.equal(calls, 1);
});
