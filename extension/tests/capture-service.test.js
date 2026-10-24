import test from 'node:test';
import assert from 'node:assert/strict';
import {saveCapture} from '../capture-service.js';
import {DEFAULT_BASE_URL} from '../platform.js';
import {CommonThreadClient} from '../../clients/javascript/client.js';
import {changeCaptureBackend, resetCaptureAttempt, writeCaptureDraft} from '../capture-state.js';

const input = {baseURL:DEFAULT_BASE_URL, token:'demo-alex', payload:{url:'https://example.com/inspiration',title:'A warm corner',selected_text:'',note:''}};
function fixture() {
  let count = 0;
  const state = {};
  const settings = {baseURL:DEFAULT_BASE_URL};
  const requests = [];
  const read = (object, names) => structuredClone(Object.fromEntries((Array.isArray(names) ? names : [names]).map(name => [name, object[name]])));
  const storage = {
    local:{get:async names => read(settings, names),set:async value => {Object.assign(settings, structuredClone(value));}},
    session:{get:async names => read(state, names),set:async value => {Object.assign(state, structuredClone(value));},
      remove:async names => {for (const name of Array.isArray(names) ? names : [names]) delete state[name];}}
  };
  const dependencies = {storage, newKey:() => `key-${++count}`, createClient:settings => ({capture:async (payload,options) => {
    assert.equal(state.saveAttempt.key, options.idempotencyKey, 'key must be persisted before network');
    requests.push({settings,payload,options});
    return {id:'save-1',status:'pending',duplicate:false};
  }})};
  return {state,settings,requests,dependencies};
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((success, failure) => {resolve = success; reject = failure;});
  return {promise, resolve, reject};
}

function delayedCapture(dependencies) {
  const started = deferred(), response = deferred();
  dependencies.createClient = () => ({capture:async () => {started.resolve(); return response.promise;}});
  return {started:started.promise, finish:result => response.resolve(result)};
}

test('a failed network request keeps the key for an unchanged retry', async () => {
  const {dependencies,state,requests} = fixture();
  const success = dependencies.createClient;
  dependencies.createClient = settings => ({capture:async (payload,options) => {
    await success(settings).capture(payload,options);
    throw new Error('Network connection interrupted');
  }});
  await assert.rejects(saveCapture(dependencies,input), /interrupted/);
  assert.equal(state.saveAttempt.status, 'pending');
  dependencies.createClient = success;
  await saveCapture(dependencies,input);
  assert.equal(requests[0].options.idempotencyKey, requests[1].options.idempotencyKey);
  assert.equal(state.saveAttempt.status, 'saved');
  assert.equal(state.captureDraft, null);
  assert.equal(state.auth.baseURL, DEFAULT_BASE_URL);
  assert.equal(state.auth.token, 'demo-alex');
  assert.ok(!JSON.stringify(state.saveAttempt).includes('demo-alex'));
});

test('replayed successful requests still reach the backend and honor deletion invalidation', async () => {
  const {dependencies,state,requests} = fixture();
  await saveCapture(dependencies,input);
  const previous = structuredClone(state.saveAttempt);
  dependencies.createClient = () => ({capture:async (payload,options) => {
    assert.equal(options.idempotencyKey, previous.key);
    throw Object.assign(new Error('Invalidated'), {code:'mutation_expired', status:410});
  }});
  await assert.rejects(saveCapture(dependencies,input), error => error.code === 'mutation_expired');
  assert.equal(state.saveAttempt.key, previous.key);
  assert.equal(requests.length, 1);
});

test('changed content or workspace token starts a distinct explicit mutation', async () => {
  const {dependencies,requests} = fixture();
  await saveCapture(dependencies,input);
  await saveCapture(dependencies,{...input,payload:{...input.payload,note:'A new note'}});
  await saveCapture(dependencies,{...input,token:'demo-sam',payload:{...input.payload,note:'A new note'}});
  assert.equal(new Set(requests.map(request => request.options.idempotencyKey)).size, 3);
});

test('stale backend settings and missing credentials fail before any network request', async () => {
  const {dependencies,requests} = fixture();
  await assert.rejects(saveCapture(dependencies,{...input,baseURL:'https://other.example.com'}), /settings changed/);
  await assert.rejects(saveCapture(dependencies,{...input,token:' '}), /workspace API token/);
  assert.equal(requests.length, 0);
});

test('capture service integrates with the shared SDK route, bearer header and mutation key', async () => {
  const {dependencies,state} = fixture();
  let sent;
  dependencies.createClient = settings => new CommonThreadClient({...settings,fetchImpl:async (url, options) => {
    sent = {url,options};
    return new Response(JSON.stringify({id:'save-sdk',status:'pending',duplicate:false}), {headers:{'Content-Type':'application/json'}});
  }});
  const result = await saveCapture(dependencies,input);
  assert.equal(result.id, 'save-sdk');
  assert.equal(sent.url, 'http://127.0.0.1:8000/v1/saves');
  assert.equal(sent.options.headers.Authorization, 'Bearer demo-alex');
  assert.equal(sent.options.headers['Idempotency-Key'], state.saveAttempt.key);
  assert.equal(JSON.parse(sent.options.body).client, 'chrome_extension');
  assert.equal(sent.options.redirect, 'error');
});

test('old completion after switching backends cannot clear a new draft or restore old account state', async () => {
  const {dependencies,state} = fixture();
  const firstDraft = await writeCaptureDraft(dependencies.storage, input);
  const old = delayedCapture(dependencies);
  const pending = saveCapture(dependencies, {...input,draftRevision:firstDraft.revision});
  await old.started;
  const next = {...input,baseURL:'https://new.example.com',payload:{...input.payload,note:'Keep this new draft'}};
  await changeCaptureBackend(dependencies.storage, next.baseURL);
  await writeCaptureDraft(dependencies.storage, next);
  const snapshot = structuredClone(state);
  old.finish({id:'old-save',status:'pending',duplicate:false});
  await pending;
  assert.deepEqual(state, snapshot);
  assert.equal(state.captureDraft.note, 'Keep this new draft');
  assert.equal(state.saveAttempt, undefined);
  assert.equal(state.auth, undefined);
});

for (const firstCompletesFirst of [true, false]) {
  test(`overlapping account saves keep the newest attempt when old completion is ${firstCompletesFirst ? 'first' : 'last'}`, async () => {
    const {dependencies,state} = fixture();
    const firstDraft = await writeCaptureDraft(dependencies.storage, input);
    const old = delayedCapture(dependencies);
    const pendingOld = saveCapture(dependencies, {...input,draftRevision:firstDraft.revision});
    await old.started;
    const next = {...input,token:'demo-sam',payload:{...input.payload,note:'Sam’s draft'}};
    const nextDraft = await writeCaptureDraft(dependencies.storage, next);
    const current = delayedCapture(dependencies);
    const pendingCurrent = saveCapture(dependencies, {...next,draftRevision:nextDraft.revision});
    await current.started;
    const latestAttempt = structuredClone(state.saveAttempt);
    if (firstCompletesFirst) {
      old.finish({id:'old-save'}); await pendingOld;
      assert.deepEqual(state.saveAttempt, latestAttempt);
      assert.equal(state.captureDraft.note, 'Sam’s draft');
      current.finish({id:'current-save'}); await pendingCurrent;
    } else {
      current.finish({id:'current-save'}); await pendingCurrent;
      old.finish({id:'old-save'}); await pendingOld;
    }
    assert.equal(state.auth.token, 'demo-sam');
    assert.equal(state.saveAttempt.result.id, 'current-save');
    assert.equal(state.saveAttempt.key, latestAttempt.key);
    assert.equal(state.captureDraft, null);
  });
}

test('editing or replacing a draft during a save preserves the new revision, even with identical text', async () => {
  for (const note of ['A later note', input.payload.note]) {
    const {dependencies,state} = fixture();
    const original = await writeCaptureDraft(dependencies.storage, input);
    const old = delayedCapture(dependencies);
    const pending = saveCapture(dependencies, {...input,draftRevision:original.revision});
    await old.started;
    const next = await writeCaptureDraft(dependencies.storage, {...input,payload:{...input.payload,note}});
    const snapshot = structuredClone(state);
    old.finish({id:'old-save'}); await pending;
    assert.deepEqual(state, snapshot);
    assert.equal(state.captureDraft.revision, next.revision);
    assert.notEqual(next.revision, original.revision);
  }
});

test('clearing an attempt prevents an in-flight response from recreating it', async () => {
  const {dependencies,state} = fixture();
  await writeCaptureDraft(dependencies.storage, input);
  const old = delayedCapture(dependencies);
  const pending = saveCapture(dependencies, input);
  await old.started;
  await resetCaptureAttempt(dependencies.storage);
  const snapshot = structuredClone(state);
  old.finish({id:'old-save'}); await pending;
  assert.deepEqual(state, snapshot);
  assert.equal(state.saveAttempt, undefined);
});

test('a queued stale draft is rejected before changing authentication or making a request', async () => {
  const {dependencies,state,requests} = fixture();
  const old = await writeCaptureDraft(dependencies.storage, input);
  await writeCaptureDraft(dependencies.storage, {...input,payload:{...input.payload,note:'Newer'}});
  const snapshot = structuredClone(state);
  await assert.rejects(saveCapture(dependencies,{...input,draftRevision:old.revision}), /draft changed/);
  assert.deepEqual(state, snapshot);
  assert.equal(requests.length, 0);
});

test('an old popup cannot reset an attempt belonging to a newer draft or connection', async () => {
  const {dependencies,state} = fixture();
  const old = await writeCaptureDraft(dependencies.storage, input);
  await writeCaptureDraft(dependencies.storage, {...input,payload:{...input.payload,note:'Newer'}});
  state.saveAttempt = {key:'current-key',status:'pending'};
  const snapshot = structuredClone(state);
  await assert.rejects(resetCaptureAttempt(dependencies.storage, {baseURL:input.baseURL,draftRevision:old.revision}), /draft or connection changed/);
  await assert.rejects(resetCaptureAttempt(dependencies.storage, {baseURL:'https://old.example.com'}), /draft or connection changed/);
  assert.deepEqual(state, snapshot);
});

test('completion checking and publication serialize with a draft edit that arrives between storage operations', async () => {
  const {dependencies,state} = fixture();
  await writeCaptureDraft(dependencies.storage, input);
  const old = delayedCapture(dependencies);
  const pending = saveCapture(dependencies, input);
  await old.started;
  const reading = deferred(), releaseRead = deferred();
  const get = dependencies.storage.session.get;
  dependencies.storage.session.get = async names => {
    const snapshot = await get(names);
    if (Array.isArray(names) && names.includes('auth')) {
      reading.resolve(); await releaseRead.promise;
    }
    return snapshot;
  };
  old.finish({id:'old-save'});
  await reading.promise;
  const editing = writeCaptureDraft(dependencies.storage, {...input,payload:{...input.payload,note:'Arrived during publication'}});
  releaseRead.resolve();
  await Promise.all([pending, editing]);
  assert.equal(state.captureDraft.note, 'Arrived during publication');
});

test('drafts retain incomplete URLs without persisting tokens or arbitrary fields', async () => {
  const {dependencies,state} = fixture();
  await writeCaptureDraft(dependencies.storage, {...input,payload:{...input.payload,url:'https://',token:'secret',unexpected:'ignored'}});
  assert.equal(state.captureDraft.url, 'https://');
  assert.equal(state.captureDraft.token, undefined);
  assert.equal(state.captureDraft.unexpected, undefined);
  assert.equal(state.auth, undefined);
});
