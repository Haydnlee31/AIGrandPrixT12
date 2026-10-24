import test from 'node:test';
import assert from 'node:assert/strict';
import {syncMultimodal, correctTranscript, searchableFind} from '../multimodal.js';
import {syncSave, sharedQuestion, answerPayload} from '../shared.js';
import {encodeWav, wavDataURL} from '../voice.js';

function fixture({audio = false, images = 2} = {}) {
  let item = {id: 'local', title: 'Watch', excerpt: 'Vintage watch', note: 'Gift for dad',
    image: 'data:image/png;base64,YQ==', images: Array(images).fill('data:image/png;base64,YQ=='),
    ...(audio ? {audio: 'data:audio/wav;base64,Yg=='} : {}), question: {id: 'basic', options: []}};
  const connection = {baseURL: 'https://example.com', userId: 'alex', multimodal: true, modern: true};
  let capture = {id: 'capture', revision: 1, status: 'pending', stage: 'draft', assets: []};
  const calls = [], receipts = new Map();
  let counter = 0;
  const clone = value => structuredClone(value);
  const once = async (method, body, options, work) => {
    calls.push({method, body: clone(body), key: options.idempotencyKey});
    if (receipts.has(options.idempotencyKey)) return clone(receipts.get(options.idempotencyKey));
    work(); receipts.set(options.idempotencyKey, clone(capture)); return clone(capture);
  };
  const api = {
    me: async () => ({user_id: 'alex'}),
    createMultimodalCapture: (body, options) => once('create', body, options, () => {}),
    getMultimodalCapture: async () => clone(capture),
    uploadMultimodalAsset: (id, body, options) => once('upload', body, options, () => {
      assert.equal(body.revision, capture.revision); capture.revision++;
      capture.assets.push({id: `asset${capture.assets.length}`, kind: body.media_type.startsWith('audio') ? 'audio' : 'image', transcript: ''});
    }),
    analyzeMultimodalCapture: (id, revision, options) => once('analyze', {revision}, options, () => {
      assert.equal(revision, capture.revision); capture.stage = 'analyzing'; capture.status = 'pending';
    }),
    waitForMultimodalCapture: async (id, {expectedRevision}) => {
      assert.equal(capture.revision, expectedRevision); capture.stage = 'ready'; capture.status = 'ready';
      for (const asset of capture.assets) if (asset.kind === 'audio' && !asset.transcript) asset.transcript = 'Avoid metal straps';
      capture.result = {analysis: {schema_version: 1, summary: 'Vintage watch'}, preview: {schema_version: 2, prompts: []}};
      return clone(capture);
    },
    updateMultimodalTranscript: (id, assetId, body, options) => once('correct', body, options, () => {
      assert.equal(capture.revision, body.revision); capture.revision++; capture.stage = 'draft'; capture.status = 'pending';
      capture.assets.find(asset => asset.id === assetId).transcript = body.transcript;
    }),
    publishMultimodalCapture: async (id, revision, options) => {
      calls.push({method: 'publish', body: {revision}, key: options.idempotencyKey});
      assert.equal(revision, capture.revision); capture.published_save_id = 'shared'; return {id: 'shared'};
    },
    waitForSave: async () => ({id: 'shared', revision: 1, status: 'ready', analysis: {summary: 'Vintage watch'}, suggestions: []}),
  };
  const args = {id: 'local', connection, api, read: async () => clone(item), update: async (_, change) => {item = change(clone(item)); return clone(item);}, key: () => `key-${++counter}`};
  return {args, calls, item: () => clone(item), capture: () => capture, set: value => {item = value;}};
}

test('images and text complete multimodal publication once, without legacy duplicate capture', async () => {
  const f = fixture();
  const result = await syncSave(f.args);
  assert.equal(result.shared.remoteId, 'shared');
  assert.equal(f.calls.filter(call => call.method === 'upload').length, 2);
  assert.equal(f.calls.filter(call => call.method === 'analyze').length, 1);
  assert.equal(f.calls.filter(call => call.method === 'publish').length, 1);
  await syncSave(f.args);
  assert.equal(f.calls.filter(call => call.method === 'publish').length, 1);
});
test('voice requires transcript review before explicit publication', async () => {
  const f = fixture({audio: true});
  await syncMultimodal(f.args);
  assert.equal(f.item().shared.remoteId, undefined);
  assert.equal(f.item().shared.mm.capture.assets.at(-1).transcript, 'Avoid metal straps');
  await syncMultimodal({...f.args, publish: true});
  assert.equal(f.item().shared.remoteId, 'shared');
  assert.equal(f.calls.filter(call => call.method === 'analyze').length, 1);
});
test('lost create reply reuses original body and key and does not create duplicate draft', async () => {
  const f = fixture(); const original = f.args.api.createMultimodalCapture;
  let fail = true;
  f.args.api.createMultimodalCapture = async (...args) => {const result = await original(...args); if (fail) {fail = false; throw Error('offline');} return result;};
  await assert.rejects(syncMultimodal(f.args), /offline/);
  await syncMultimodal(f.args);
  assert.deepEqual(f.calls[0], f.calls[1]);
});
test('lost upload reply replays original revision and body even when server advanced', async () => {
  const f = fixture(); const original = f.args.api.uploadMultimodalAsset;
  let fail = true;
  f.args.api.uploadMultimodalAsset = async (...args) => {const result = await original(...args); if (fail) {fail = false; throw Error('interrupted');} return result;};
  await assert.rejects(syncMultimodal(f.args), /interrupted/);
  await syncMultimodal(f.args);
  const uploads = f.calls.filter(call => call.method === 'upload');
  assert.deepEqual(uploads[0], uploads[1]);
  assert.equal(f.capture().assets.length, 2);
});
test('lost publication reply recovers published ID without a second save', async () => {
  const f = fixture(); const original = f.args.api.publishMultimodalCapture;
  f.args.api.publishMultimodalCapture = async (...args) => {await original(...args); throw Error('lost reply');};
  await assert.rejects(syncMultimodal(f.args), /lost reply/);
  await syncMultimodal(f.args);
  assert.equal(f.item().shared.remoteId, 'shared');
  assert.equal(f.calls.filter(call => call.method === 'publish').length, 1);
});
test('transcript correction is durable and reanalyzes without uploading or transcribing again', async () => {
  const f = fixture({audio: true});
  await syncMultimodal(f.args);
  await correctTranscript({...f.args, text: 'I prefer metal straps'});
  const original = f.args.api.updateMultimodalTranscript; let fail = true;
  f.args.api.updateMultimodalTranscript = async (...args) => {const result = await original(...args); if (fail) {fail = false; throw Error('interrupted');} return result;};
  await assert.rejects(syncMultimodal(f.args), /interrupted/);
  await syncMultimodal(f.args);
  const corrections = f.calls.filter(call => call.method === 'correct');
  assert.deepEqual(corrections[0], corrections[1]);
  assert.equal(f.calls.filter(call => call.method === 'upload').length, 3);
  assert.equal(f.calls.filter(call => call.method === 'analyze').length, 2);
  assert.equal(f.item().shared.mm.capture.assets.at(-1).transcript, 'I prefer metal straps');
});
test('account and origin changes cannot replay another accounts pending media', async () => {
  const f = fixture({audio: true}); await syncMultimodal(f.args);
  await assert.rejects(syncMultimodal({...f.args, connection: {...f.args.connection, userId: 'sam'}}), /original account/);
  await assert.rejects(syncMultimodal({...f.args, connection: {...f.args.connection, baseURL: 'https://other.example'}}), /original account/);
});
test('session change while request is in flight stops publication and local response mutation', async () => {
  const f = fixture(); let active = true;
  const original = f.args.api.createMultimodalCapture;
  f.args.api.createMultimodalCapture = async (...args) => {const capture = await original(...args); active = false; return capture;};
  await assert.rejects(syncMultimodal({...f.args, guard: async () => {if (!active) throw Error('connection changed');}}), /connection changed/);
  assert.equal(f.item().shared.mm.captureId, undefined);
  assert.equal(f.calls.length, 1);
});
test('failed jobs only retry after explicit request with a new analysis key', async () => {
  const f = fixture({audio: true}); await syncMultimodal(f.args);
  f.capture().stage = 'failed'; f.capture().status = 'enrichment_failed';
  await assert.rejects(syncMultimodal(f.args), /Retry analysis/);
  await syncMultimodal({...f.args, retryUnderstanding: true});
  const attempts = f.calls.filter(call => call.method === 'analyze');
  assert.equal(attempts.length, 2); assert.notEqual(attempts[0].key, attempts[1].key);
});
test('contextual predictive choices become explicit edited intents, not invented server IDs', () => {
  const remote = {id: 's', revision: 2, features: {multimodal_preview: {schema_version: 2, prompts: [{id:'p1', text:'I like the vintage face'}]}}, suggestions: [{id:'intent', text:'Keep'}]};
  const question = sharedQuestion(remote);
  assert.equal(question.options[0].label, 'I like the vintage face');
  assert.deepEqual(answerPayload({answer: {kind:'choice', optionId:'preview:p1', label:question.options[0].label}, shared:{remote}}), {action:'edit',text:'I like the vintage face'});
});
test('Library search includes fine analysis categories and reviewed voice words', () => {
  const item = {title:'Watch',shared:{mm:{capture:{result:{analysis:{products:[{category_path:['Fashion','Watches','Digital']}] }},assets:[{transcript:'Birthday gift for dad'}]}}}};
  assert.match(searchableFind(item), /digital/); assert.match(searchableFind(item), /birthday/);
});
test('recorded audio is bounded 16kHz PCM WAV with correct RIFF length', () => {
  const data = encodeWav(new Float32Array(48000).fill(.5), 48000);
  const view = new DataView(data.buffer);
  assert.equal(new TextDecoder().decode(data.subarray(0, 4)), 'RIFF');
  assert.equal(view.getUint32(24,true),16000); assert.equal(view.getUint16(22,true),1);
  assert.equal(view.getUint32(40,true),32000); assert.equal(data.length,32044);
  assert.match(wavDataURL(data), /^data:audio\/wav;base64,/);
  assert.throws(() => encodeWav(new Float32Array(0), 16000), /empty/);
  assert.throws(() => encodeWav(new Float32Array(16000*62), 16000), /60 seconds/);
});
test('multi-image or voice capture cannot silently downgrade to a server without multimodal', async () => {
  const f = fixture({audio:true}); f.args.connection.multimodal = false;
  await assert.rejects(syncSave(f.args), /does not have multimodal/);
  assert.equal(f.calls.length, 0); assert.ok(f.item().audio);
});
test('offline queued capture cannot be sent after switching accounts before its first request', async () => {
  const f = fixture(); f.set({...f.item(), queuedScope: JSON.stringify(['https://example.com', 'sam'])});
  await assert.rejects(syncSave(f.args), /queued for another account/);
  assert.equal(f.calls.length, 0);
});
