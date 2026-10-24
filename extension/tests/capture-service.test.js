import test from 'node:test';
import assert from 'node:assert/strict';
import {saveCapture} from '../capture-service.js';
import {DEFAULT_BASE_URL} from '../platform.js';
import {CommonThreadClient} from '../../clients/javascript/client.js';

const input = {baseURL:DEFAULT_BASE_URL, token:'demo-alex', payload:{url:'https://example.com/inspiration',title:'A warm corner',selected_text:'',note:''}};
function fixture() {
  let count = 0;
  const state = {};
  const requests = [];
  const storage = {
    local:{get:async () => ({baseURL:DEFAULT_BASE_URL})},
    session:{get:async name => ({[name]:state[name]}),set:async value => {Object.assign(state, structuredClone(value));}}
  };
  const dependencies = {storage, newKey:() => `key-${++count}`, createClient:settings => ({capture:async (payload,options) => {
    assert.equal(state.saveAttempt.key, options.idempotencyKey, 'key must be persisted before network');
    requests.push({settings,payload,options});
    return {id:'save-1',status:'pending',duplicate:false};
  }})};
  return {state,requests,dependencies};
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
