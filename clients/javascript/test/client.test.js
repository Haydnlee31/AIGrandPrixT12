import test from 'node:test';
import assert from 'node:assert/strict';
import {CommonThreadClient, APIError} from '../client.js';

const reply = (data, status=200) => new Response(JSON.stringify(data), {status,headers:{'Content-Type':'application/json','X-Request-ID':'request-1'}});

test('browser fetch retains its global receiver', async () => {
  const client=new CommonThreadClient({fetchImpl:function () { assert.equal(this,globalThis);return Promise.resolve(reply({user_id:'account'})); }});
  assert.equal((await client.me()).user_id,'account');
});

test('mutations require a retained key; exact retries preserve body and key', async () => {
  const calls=[];
  const client=new CommonThreadClient({token:'local-test',fetchImpl:async (...args)=>{calls.push(args);return reply({id:'save-1',status:'pending',duplicate:false});}});
  await assert.rejects(client.capture({url:'https://example.com',title:'Desk'}), TypeError);
  const body={url:'https://example.com',title:'Desk',client:'chrome_extension'};
  await client.capture(body,{idempotencyKey:'original-key'});
  await client.capture(body,{idempotencyKey:'original-key'});
  assert.equal(calls.length,2);
  assert.equal(calls[0][1].body,calls[1][1].body);
  assert.equal(calls[0][1].headers['Idempotency-Key'],'original-key');
  assert.equal(calls[0][1].headers.Authorization,'Bearer local-test');
  assert.equal(calls[0][1].redirect,'error');
});

test('preserves a stale session response for reconciliation without retrying', async () => {
  let calls=0;
  const client=new CommonThreadClient({fetchImpl:async ()=>{calls++;return reply({error:{code:'stale_version',message:'Refresh',retryable:false,request_id:'server-id',current:{version:4}}},409);}});
  await assert.rejects(client.discoveryEvent('s',{expected_version:3,action:'retrieve'},{idempotencyKey:'event-1'}), e => e instanceof APIError && e.status===409 && e.current.version===4 && e.requestId==='server-id' && !e.retryable);
  assert.equal(calls,1);
});

test('rejects cross-origin credential leaks and insecure remote servers', async () => {
  assert.throws(()=>new CommonThreadClient({baseURL:'http://remote.example.com'}), TypeError);
  assert.throws(()=>new CommonThreadClient({baseURL:'https://secret@api.example.com'}), TypeError);
  const client=new CommonThreadClient({baseURL:'https://api.example.com'});
  await assert.rejects(client.request('//untrusted.example.com'), TypeError);
  await assert.rejects(client.request('https://untrusted.example.com'), TypeError);
});

test('network uncertainty is retryable, while deletion tombstone is terminal', async () => {
  const offline=new CommonThreadClient({fetchImpl:async()=>{throw new TypeError('offline');}});
  await assert.rejects(offline.me(),e=>e.code==='network_error' && e.retryable);
  const expired=new CommonThreadClient({fetchImpl:async()=>reply({error:{code:'mutation_expired',message:'Deleted',retryable:false,request_id:'r'}},410)});
  await assert.rejects(expired.capture({},{idempotencyKey:'old'}),e=>e.status===410 && !e.retryable);
});

test('pending save polling stops on enrichment failure without claiming save failed', async () => {
  let count=0;
  const client=new CommonThreadClient({fetchImpl:async()=>reply({id:'s',status:++count===1?'pending':'enrichment_failed'})});
  assert.equal((await client.waitForSave('s',{intervalMs:100})).status,'enrichment_failed');
  assert.equal(count,2);
});

test('bounded polling times out and is cancellable', async () => {
  const client=new CommonThreadClient({fetchImpl:async()=>reply({id:'s',status:'pending'})});
  await assert.rejects(client.waitForSave('s',{timeoutMs:0}),e=>e.code==='processing_timeout');
  const controller=new AbortController();
  const pending=client.waitForSave('s',{intervalMs:1000,signal:controller.signal});
  setTimeout(()=>controller.abort(),5);
  await assert.rejects(pending,e=>e.name==='AbortError');
});

test('unreadable success keeps unknown mutation outcome visible', async () => {
  const client=new CommonThreadClient({fetchImpl:async()=>new Response('gateway error',{status:502})});
  await assert.rejects(client.createWatch({variant_id:'x',target_minor:100},{idempotencyKey:'w'}),e=>e.code==='invalid_response' && e.retryable && e.status===502);
});

test('stalled requests time out without forgetting mutation identity', async () => {
  let key;
  const client = new CommonThreadClient({fetchImpl:(_, options) => new Promise((resolve,reject) => {
    key = options.headers['Idempotency-Key'];
    options.signal.addEventListener('abort', () => reject(options.signal.reason), {once:true});
  })});
  await assert.rejects(client.capture({url:'https://example.com'},{idempotencyKey:'retained',timeoutMs:5}), e => e.code==='request_timeout' && e.retryable);
  assert.equal(key,'retained');
  await assert.rejects(client.waitForSave('s',{intervalMs:NaN}),TypeError);
  await assert.rejects(client.waitForSave('s',{timeoutMs:Infinity}),TypeError);
});

test('timeout while reading the body remains distinguishable from invalid JSON', async () => {
  const client = new CommonThreadClient({fetchImpl:async (_, {signal}) => ({headers:new Headers(),status:200,ok:true,json:() => new Promise((resolve,reject) => signal.addEventListener('abort',()=>reject(signal.reason),{once:true}))})});
  await assert.rejects(client.me({timeoutMs:5}),e=>e.code==='request_timeout');
});
