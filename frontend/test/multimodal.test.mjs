import test from 'node:test';
import assert from 'node:assert/strict';
import {saveSharedCapture} from '../multimodal.mjs';

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
