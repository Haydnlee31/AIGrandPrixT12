import test from 'node:test';
import assert from 'node:assert/strict';
import {CommonThreadClient, APIError} from '../client.js';

const reply = data => new Response(JSON.stringify(data), {headers:{'Content-Type':'application/json'}});
const pending = (stage = 'analyzing', revision = 3) => ({id:'capture-1', revision, status:'pending', stage, result:null});
const ready = (revision = 3) => ({...pending('ready', revision), status:'ready', result:{analysis:{schema_version:1}, preview:{schema_version:2}, source_assets:['image-1']}});

test('multimodal methods reuse authenticated transport, explicit revisions and retained mutation keys', async () => {
  const requests=[];
  const client=new CommonThreadClient({token:'fixture-token', fetchImpl:async (url, options)=>{
    requests.push({path:new URL(url).pathname, ...options}); return reply(pending());
  }});
  const options={idempotencyKey:'persisted-key'};
  const upload={revision:2, media_type:'audio/wav', data_base64:'Ynl0ZXM='};
  await client.multimodalCapabilities();
  await client.createMultimodalCapture({note:'A gift',client:'chrome_extension'},options);
  await client.getMultimodalCapture('capture-1');
  await client.uploadMultimodalAsset('capture-1',upload,options);
  await client.uploadMultimodalAsset('capture-1',upload,options);
  await client.updateMultimodalCapture('capture-1',{revision:3,note:''},options);
  await client.updateMultimodalTranscript('capture-1','audio-1',{revision:4,transcript:'A gift for Dad'},options);
  await client.analyzeMultimodalCapture('capture-1',4,options);
  await client.deleteMultimodalAsset('capture-1','asset + 1',4,options);
  await client.publishMultimodalCapture('capture-1',5,options);
  await client.deleteMultimodalCapture('capture-1',options);
  assert.deepEqual(requests.map(r=>[r.method,r.path]),[
    ['GET','/v1/multimodal/capabilities'], ['POST','/v1/multimodal/captures'],
    ['GET','/v1/multimodal/captures/capture-1'],
    ['POST','/v1/multimodal/captures/capture-1/assets'], ['POST','/v1/multimodal/captures/capture-1/assets'],
    ['PATCH','/v1/multimodal/captures/capture-1'], ['PATCH','/v1/multimodal/captures/capture-1/assets/audio-1'], ['POST','/v1/multimodal/captures/capture-1/analyze'],
    ['DELETE','/v1/multimodal/captures/capture-1/assets/asset%20%2B%201'],
    ['POST','/v1/multimodal/captures/capture-1/publish'], ['DELETE','/v1/multimodal/captures/capture-1']
  ]);
  assert.equal(requests[3].body,requests[4].body);
  assert.deepEqual(JSON.parse(requests[3].body),upload);
  assert.deepEqual(JSON.parse(requests[5].body),{revision:3,note:''});
  assert.deepEqual(JSON.parse(requests[6].body),{revision:4,transcript:'A gift for Dad'});
  assert.deepEqual(JSON.parse(requests[7].body),{revision:4});
  assert.deepEqual(JSON.parse(requests[8].body),{revision:4});
  assert.deepEqual(JSON.parse(requests[9].body),{revision:5});
  assert.equal(requests[10].body,undefined);
  assert.ok(requests.every(r=>r.headers.Authorization==='Bearer fixture-token' && r.cache==='no-store' && r.redirect==='error'));
  assert.ok(requests.filter(r=>r.method!=='GET').every(r=>r.headers['Idempotency-Key']==='persisted-key'));
});

test('multimodal validation rejects unsafe IDs and invalid revisions without sending a request', async () => {
  let calls=0;
  const client=new CommonThreadClient({fetchImpl:async()=>{calls++;return reply({});}});
  const options={idempotencyKey:'key'};
  for (const id of ['', '.', '..', '../capture', 'a/b', 'a\\b', 'id\n', 'x'.repeat(201)]) {
    assert.throws(()=>client.getMultimodalCapture(id),TypeError);
    assert.throws(()=>client.deleteMultimodalAsset('capture',id,1,options),TypeError);
  }
  for (const revision of [0,-1,1.5,NaN,Infinity,Number.MAX_SAFE_INTEGER+1]) {
    assert.throws(()=>client.analyzeMultimodalCapture('capture',revision,options),TypeError);
    assert.throws(()=>client.publishMultimodalCapture('capture',revision,options),TypeError);
    assert.throws(()=>client.uploadMultimodalAsset('capture',{revision},options),TypeError);
  }
  await assert.rejects(client.createMultimodalCapture({}),TypeError);
  await assert.rejects(client.updateMultimodalCapture('capture',{revision:1}),TypeError);
  assert.equal(calls,0);
});

test('multimodal polling waits across transcription and analysis without publishing anything', async () => {
  const results=[pending('transcribing'),pending('analyzing'),ready()];
  const calls=[];
  const client=new CommonThreadClient({fetchImpl:async(url,options)=>{
    calls.push([url,options]); return reply(results.shift());
  }});
  const result=await client.waitForMultimodalCapture('capture-1',{expectedRevision:3,intervalMs:100});
  assert.equal(result.status,'ready');
  assert.equal(calls.length,3);
  assert.ok(calls.every(([url,options])=>options.method==='GET' && new URL(url).pathname==='/v1/multimodal/captures/capture-1'));
});

test('multimodal terminal failures preserve error code without retrying or claiming the capture was lost', async () => {
  let calls=0;
  const client=new CommonThreadClient({fetchImpl:async()=>{calls++;return reply({...pending('failed'),status:'enrichment_failed',error_code:'astra_rate_limited'});}});
  await assert.rejects(client.waitForMultimodalCapture('capture-1'), error=>error instanceof APIError && error.code==='astra_rate_limited' && /stored/.test(error.message) && !error.retryable);
  assert.equal(calls,1);
});

test('multimodal polling refuses a result from a changed capture revision', async () => {
  const client=new CommonThreadClient({fetchImpl:async()=>reply(ready(4))});
  await assert.rejects(client.waitForMultimodalCapture('capture-1',{expectedRevision:3}), error=>error.code==='stale_revision' && !error.retryable);
});

test('multimodal polling never treats missing results or unknown outer statuses as success', async () => {
  for (const response of [null,{...ready(),result:null},{...ready(),result:{analysis:{schema_version:2},preview:{schema_version:2}}},{...pending(),status:'transcribing'},{...ready(),id:'other-capture'},{...ready(),revision:0}]) {
    const client=new CommonThreadClient({fetchImpl:async()=>reply(response)});
    await assert.rejects(client.waitForMultimodalCapture('capture-1'),error=>error.code==='invalid_response');
  }
});

test('multimodal polling is bounded and cancels while waiting between stages', async () => {
  let calls=0;
  const client=new CommonThreadClient({fetchImpl:async()=>{calls++;return reply(pending());}});
  await assert.rejects(client.waitForMultimodalCapture('capture-1',{timeoutMs:0}),error=>error.code==='processing_timeout');
  assert.equal(calls,0);
  const controller=new AbortController();
  const waiting=client.waitForMultimodalCapture('capture-1',{intervalMs:1000,signal:controller.signal});
  setTimeout(()=>controller.abort(),5);
  await assert.rejects(waiting,error=>error.name==='AbortError');
  assert.equal(calls,1);
  await assert.rejects(client.waitForMultimodalCapture('capture-1',{signal:controller.signal}),error=>error.name==='AbortError');
  assert.equal(calls,1);
  for (const options of [{intervalMs:99},{intervalMs:NaN},{timeoutMs:Infinity},{timeoutMs:86400001},{expectedRevision:0}]) {
    await assert.rejects(client.waitForMultimodalCapture('capture-1',options),TypeError);
  }
});

test('multimodal polling bounds a stalled read using the shared transport timeout', async () => {
  const client=new CommonThreadClient({fetchImpl:(_,options)=>new Promise((resolve,reject)=>{
    options.signal.addEventListener('abort',()=>reject(options.signal.reason),{once:true});
  })});
  await assert.rejects(client.waitForMultimodalCapture('capture-1',{timeoutMs:5}),error=>error.code==='request_timeout' && error.retryable);
});

test('multimodal polling checks cancellation before publishing even if a transport finishes concurrently', async () => {
  const controller=new AbortController();
  const client=new CommonThreadClient({fetchImpl:async()=>{controller.abort();return reply(ready());}});
  await assert.rejects(client.waitForMultimodalCapture('capture-1',{signal:controller.signal}),error=>error.name==='AbortError');
});
