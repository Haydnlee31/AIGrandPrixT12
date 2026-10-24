import test from 'node:test';
import assert from 'node:assert/strict';
import {saveSharedCapture, contextualPrompts} from '../multimodal.mjs';

function fixture() {
  const calls = [], attempt = {key:'save-key', accountId:'alex', payload:{title:'Watch', note:'Birthday gift', image_data_url:'data:image/png;base64,AAAA'}};
  let stored;
  const persist = value => { stored = structuredClone(value); };
  const api = {
    multimodalCapabilities: async () => ({enabled:true}),
    createMultimodalCapture: async (body, opts) => { calls.push(['create', body, opts]); return {id:'capture-1', revision:1}; },
    uploadMultimodalAsset: async (id, body, opts) => { calls.push(['upload', body, opts]); return {id, revision:2}; },
    analyzeMultimodalCapture: async (id, revision, opts) => { calls.push(['analyze', revision, opts]); },
    waitForMultimodalCapture: async () => ({status:'ready'}),
    publishMultimodalCapture: async (id, revision, opts) => { calls.push(['publish', revision, opts]); return {id:'save-1'}; },
  };
  return {api, attempt, calls, persist, stored: () => stored};
}

test('web save performs real pipeline lifecycle and persists before upload/analyze', async () => {
  const f = fixture();
  assert.deepEqual(await saveSharedCapture(f.api, f.attempt, f.persist), {id:'save-1'});
  assert.deepEqual(f.calls.map(call => call[0]), ['create','upload','analyze','publish']);
  assert.equal(f.stored().multimodal.revision, 2);
  assert.equal(f.calls[3][2].idempotencyKey, 'save-key:publish');
});

test('uncertain upload response retains original revision and key across tab restart', async () => {
  const f = fixture(); const upload = f.api.uploadMultimodalAsset;
  f.api.uploadMultimodalAsset = async (...args) => {await upload(...args); throw new Error('connection lost');};
  await assert.rejects(saveSharedCapture(f.api, f.attempt, f.persist));
  f.api.uploadMultimodalAsset = upload;
  await saveSharedCapture(f.api, f.stored(), f.persist);
  const uploads = f.calls.filter(call => call[0] === 'upload');
  assert.deepEqual(uploads[0], uploads[1]);
  assert.equal(f.calls.filter(call => call[0] === 'create').length, 1);
});

test('poll failure retries existing analysis without duplicating jobs', async () => {
  const f = fixture();
  f.api.waitForMultimodalCapture = async () => {throw new Error('timeout');};
  await assert.rejects(saveSharedCapture(f.api, f.attempt, f.persist));
  f.api.waitForMultimodalCapture = async () => ({status:'ready'});
  await saveSharedCapture(f.api, f.stored(), f.persist);
  assert.equal(f.calls.filter(call => call[0] === 'analyze').length, 1);
});

test('missing capability supports legacy server, authentication errors do not downgrade', async () => {
  const f = fixture();
  f.api.multimodalCapabilities = async () => {throw {status:401};};
  await assert.rejects(saveSharedCapture(f.api, f.attempt, f.persist));
  f.api.multimodalCapabilities = async () => {throw {status:404};};
  f.api.capture = async (_, opts) => ({id:opts.idempotencyKey});
  assert.deepEqual(await saveSharedCapture(f.api, f.attempt, f.persist), {id:'save-key'});
});

test('terminal failure stops automatic work and explicit retry reuses uploaded assets', async () => {
  const f = fixture();
  f.api.waitForMultimodalCapture = async () => {throw new Error('analysis failed');};
  f.api.getMultimodalCapture = async () => ({status:'enrichment_failed'});
  await assert.rejects(saveSharedCapture(f.api, f.attempt, f.persist), error => error.status === 422);
  assert.equal(f.stored().paused, true);
  await assert.rejects(saveSharedCapture(f.api, f.stored(), f.persist));
  f.api.waitForMultimodalCapture = async () => ({status:'ready'});
  await saveSharedCapture(f.api, f.stored(), f.persist, () => {}, {retryFailed:true});
  assert.equal(f.calls.filter(call => call[0] === 'upload').length, 1);
  const analyses = f.calls.filter(call => call[0] === 'analyze');
  assert.equal(analyses.length, 2);
  assert.notEqual(analyses[0][2].idempotencyKey, analyses[1][2].idempotencyKey);
});

test('selected text from the actual capture form reaches multimodal analysis', async () => {
  const f = fixture();
  f.attempt.payload.selected_text = 'Rectangular digital watch with a black strap';
  await saveSharedCapture(f.api, f.attempt, f.persist);
  assert.equal(f.calls[0][1].text, f.attempt.payload.selected_text);
  assert.equal(f.calls[0][1].note, 'Birthday gift');
});

test('account switch during upload stops analysis and preserves original retry identity', async () => {
  const f = fixture(); let current = true;
  const upload = f.api.uploadMultimodalAsset;
  f.api.uploadMultimodalAsset = async (...args) => { const value = await upload(...args); current = false; return value; };
  await assert.rejects(saveSharedCapture(f.api, f.attempt, f.persist, () => {}, {isCurrent:() => current}), {name:'AbortError'});
  assert.deepEqual(f.calls.map(call => call[0]), ['create','upload']);
  const kept = f.stored();
  assert.equal(kept.multimodal.uploaded, undefined);
  current = true; f.api.uploadMultimodalAsset = upload;
  await saveSharedCapture(f.api, kept, f.persist, () => {}, {isCurrent:() => current});
  const uploads = f.calls.filter(call => call[0] === 'upload');
  assert.deepEqual(uploads[0], uploads[1]);
});

test('disconnect while polling cannot publish an old account capture', async () => {
  const f = fixture(), controller = new AbortController();
  f.api.waitForMultimodalCapture = async (_, options) => {
    assert.equal(options.signal, controller.signal);
    controller.abort();
    return {status:'ready'};
  };
  await assert.rejects(saveSharedCapture(f.api, f.attempt, f.persist, () => {}, {signal:controller.signal}), {name:'AbortError'});
  assert.equal(f.calls.some(call => call[0] === 'publish'), false);
  assert.equal(f.stored().multimodal.analyzed, true);
});

test('uncertain create and publication receipts replay the same stages and keys', async () => {
  const f = fixture(); const create = f.api.createMultimodalCapture;
  f.api.createMultimodalCapture = async (...args) => { await create(...args); throw new Error('closed tab'); };
  await assert.rejects(saveSharedCapture(f.api, f.attempt, f.persist));
  f.api.createMultimodalCapture = create;
  const publish = f.api.publishMultimodalCapture;
  f.api.publishMultimodalCapture = async (...args) => { await publish(...args); throw new Error('closed tab'); };
  await assert.rejects(saveSharedCapture(f.api, f.stored(), f.persist));
  f.api.publishMultimodalCapture = publish;
  await saveSharedCapture(f.api, f.stored(), f.persist);
  const creates = f.calls.filter(call => call[0] === 'create');
  const publications = f.calls.filter(call => call[0] === 'publish');
  assert.deepEqual(creates[0], creates[1]);
  assert.deepEqual(publications[0], publications[1]);
  assert.equal(f.calls.filter(call => call[0] === 'upload').length, 1);
  assert.equal(f.calls.filter(call => call[0] === 'analyze').length, 1);
});

test('shared contextual prompts retain exact model choices and reject malformed projections', () => {
  const prompts = ['p1','p2','p3'].map(id => ({id, text:`My preference ${id}`, question:`Does ${id} appeal to you?`}));
  const item = {features:{multimodal_preview:{schema_version:2, prompts}}};
  assert.deepEqual(contextualPrompts(item), prompts);
  assert.deepEqual(contextualPrompts({features:{multimodal_preview:{schema_version:1, prompts}}}), []);
  assert.deepEqual(contextualPrompts({features:{multimodal_preview:{schema_version:2, prompts:prompts.slice(0,2)}}}), []);
  assert.deepEqual(contextualPrompts({features:{multimodal_preview:{schema_version:2, prompts:[...prompts.slice(0,2), {...prompts[2],id:'buy'}]}}}), []);
});
