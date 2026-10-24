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

test('image-only captures preserve private image payload and annotation intent without executing actions', async () => {
  const calls=[];
  const client=new CommonThreadClient({token:'account-token',fetchImpl:async (url,options)=>{
    calls.push([new URL(url),options]);
    if (new URL(url).pathname.endsWith('/responses')) return reply({event_id:'intent-1',intent:'remind_later',execution_status:'annotation_only'});
    if (options.method==='POST') return reply({id:'save-image',status:'pending',duplicate:false},201);
    return reply({id:'save-image',original_url:'',has_image:true,image_path:'/v1/saves/save-image/image',status:'ready',suggestions:[
      {id:'suggestion-1',kind:'intent',text:'Remind me about this tomorrow',intent:'remind_later',requires_confirmation:true}
    ]});
  }});
  const payload={title:'Saved chair',source:'product',client:'chrome_extension',image_data_url:'data:image/png;base64,aW1hZ2U='};
  await client.capture(payload,{idempotencyKey:'image-action'});
  await client.capture(payload,{idempotencyKey:'image-action'});
  assert.equal(calls[0][1].body,calls[1][1].body);
  assert.deepEqual(JSON.parse(calls[0][1].body),payload);
  assert.equal(calls[0][1].headers.Authorization,'Bearer account-token');
  const item=await client.getSave('save-image');
  assert.equal(item.has_image,true);
  assert.equal(item.image_path,'/v1/saves/save-image/image');
  assert.equal(item.suggestions[0].requires_confirmation,true);
  assert.equal(item.suggestions[0].intent,'remind_later');
  const result=await client.respond(item.id,{action:'select',suggestion_id:'suggestion-1'},{idempotencyKey:'annotation-action'});
  assert.equal(result.intent,'remind_later');
  assert.equal(result.execution_status,'annotation_only');
  assert.deepEqual(calls.map(([url])=>url.pathname),['/v1/saves','/v1/saves','/v1/saves/save-image','/v1/saves/save-image/responses']);
  assert.deepEqual(JSON.parse(calls[3][1].body),{action:'select',suggestion_id:'suggestion-1'});
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

test('catalog queries preserve source, Unicode text and record IDs without caching response data', async () => {
  const requests=[];
  const client=new CommonThreadClient({token:'local-test',fetchImpl:async (url,options)=>{
    requests.push([new URL(url),options]); return reply({items:[]});
  }});
  await client.catalogSources();
  await client.searchProducts({source:'open_beauty_facts',query:'lamp + café & q=other',limit:10,offset:10001});
  await client.catalogItem('uci_retail','sku:123 + café #1?');
  assert.equal(requests[0][0].pathname,'/v1/commerce/sources');
  assert.equal(requests[1][0].searchParams.get('q'),'lamp + café & q=other');
  assert.equal(requests[1][0].searchParams.get('source'),'open_beauty_facts');
  assert.equal(requests[1][0].searchParams.get('offset'),'10001');
  assert.equal(requests[1][0].searchParams.has('delivery_country'),false);
  assert.equal(requests[2][0].pathname,'/v1/commerce/items/uci_retail/sku%3A123%20%2B%20caf%C3%A9%20%231%3F');
  assert.ok(requests.every(([,options])=>options.cache==='no-store' && options.method==='GET' && !options.body));
  for (const source of ['', '../sources', 'Uppercase', 'abo\n', 'a'.repeat(65)]) {
    assert.throws(()=>client.searchProducts({source,query:'lamp'}),TypeError);
    assert.throws(()=>client.catalogItem(source,'sku'),TypeError);
  }
  for (const query of ['', '  ', 'a'.repeat(101), 'lamp\n']) assert.throws(()=>client.searchProducts({source:'abo',query}),TypeError);
  for (const [limit,offset] of [[0,0],[51,0],[20,-1],[20,1000000],[2.5,0]]) assert.throws(()=>client.searchProducts({source:'abo',query:'lamp',limit,offset}),TypeError);
  for (const id of ['', '.', '..', '../sku', 'sku\\name', 'sku\n', 'a'.repeat(1025)]) assert.throws(()=>client.catalogItem('abo',id),TypeError);
  assert.throws(()=>client.searchProducts({source:'abo',query:'lamp',deliveryCountry:'SG'}),TypeError);
  assert.equal(requests.length,3);
});

test('catalog preserves absent current-offer facts and lets the backend reject unregistered sources', async () => {
  const record={source_id:'uci_retail',source_record_id:'sku',data_kind:'open_dataset',
    offer:{url:null,observed_at:null,expires_at:null,price_minor:null,shipping_minor:null},
    provenance:{license_id:'CC-BY-4.0'}};
  const client=new CommonThreadClient({fetchImpl:async url=>{
    if (new URL(url).searchParams.get('source')==='future_source') {
      return reply({error:{code:'unknown_source',message:'Unknown source.',retryable:false,request_id:'catalog-source'}},422);
    }
    return reply(record);
  }});
  const product=await client.catalogItem('uci_retail','sku');
  assert.equal(product.data_kind,'open_dataset');
  assert.equal(product.offer.expires_at,null);
  assert.equal(product.offer.price_minor,null);
  assert.equal(product.provenance.license_id,'CC-BY-4.0');
  await assert.rejects(client.searchProducts({source:'future_source',query:'lamp'}),e=>e.code==='unknown_source' && !e.retryable && e.requestId==='catalog-source');
});

test('Library analysis search and Explore preserve query, source citations and unknown offers', async () => {
  const calls=[];
  const product={source_id:'abo',source_record_id:'watch-1',offer:{price_minor:null,url:null}};
  const cited={product,score:12,score_kind:'heuristic_match',reasons:[{kind:'attribute_match',saved_item_id:'mine',saved_item_revision:3,analysis_path:'products.0.attributes.0.value',matched_value:'vintage',catalog_field:'title',catalog_value:'Vintage watch'}],catalog_citation:{source_id:'abo',record_id:'watch-1',license_id:'CC-BY-4.0'},action:'view_source',action_url:null};
  const client=new CommonThreadClient({token:'account-token',fetchImpl:async (url,options)=>{
    const parsed=new URL(url); calls.push([parsed,options]);
    return reply(parsed.pathname==='/v1/library/search'
      ? {items:[{id:'mine',analysis:null,analysis_status:'pending'}],total:1,next_offset:null,query:parsed.searchParams.get('q'),category:parsed.searchParams.get('category')}
      : {items:[cited],source_id:'abo',mode:'personalized',status:'ready',next_offset:null});
  }});
  const library=await client.searchLibrary({query:'vintage + café watch',category:'Wristwatches',offset:12,limit:10});
  assert.equal(library.items[0].analysis,null);
  assert.equal(library.items[0].analysis_status,'pending');
  assert.equal(calls[0][0].searchParams.get('q'),'vintage + café watch');
  assert.equal(calls[0][0].searchParams.get('category'),'Wristwatches');
  assert.equal(calls[0][0].searchParams.get('offset'),'12');
  const recommendations=await client.explore();
  assert.equal(calls[1][0].pathname,'/v1/explore');
  assert.equal(calls[1][0].searchParams.has('source'),false);
  assert.equal(recommendations.items[0].reasons[0].saved_item_id,'mine');
  assert.equal(recommendations.items[0].product.offer.price_minor,null);
  assert.equal(recommendations.items[0].catalog_citation.source_id,'abo');
  assert.equal(recommendations.items[0].action_url,null);
  await client.explore({source:'wands',query:'lamp & shade',limit:5,offset:10});
  assert.equal(calls[2][0].searchParams.get('source'),'wands');
  assert.equal(calls[2][0].searchParams.get('q'),'lamp & shade');
  assert.ok(calls.every(([,options])=>options.cache==='no-store' && options.headers.Authorization==='Bearer account-token'));
});

test('analysis refresh retains mutation identity without reuploading private media', async () => {
  const requests=[];
  const client=new CommonThreadClient({fetchImpl:async (url,options)=>{
    requests.push([new URL(url),options]);return reply({id:'saved-id',status:'pending',revision:2,job_id:'job-id',queued:true});
  }});
  await assert.rejects(client.analyzeSave('saved-id'),TypeError);
  const result=await client.analyzeSave('saved-id',{idempotencyKey:'reanalyze-1'});
  await client.analyzeSave('saved-id',{idempotencyKey:'reanalyze-1'});
  assert.equal(result.revision,2);
  assert.ok(requests.every(([url,options])=>url.pathname==='/v1/saves/saved-id/analyze' && options.method==='POST' && options.body===undefined && options.headers['Idempotency-Key']==='reanalyze-1'));
  for (const id of ['', '..', '../other', 'a/b', 'id\n']) assert.throws(()=>client.analyzeSave(id,{idempotencyKey:'unused'}),TypeError);
  assert.equal(requests.length,2);
});

test('AI search validates bounds and preserves an honest empty Explore state', async () => {
  let requests=0;
  const client=new CommonThreadClient({fetchImpl:async ()=>{requests++;return reply({items:[],status:'needs_saves',mode:'personalized',next_offset:null});}});
  assert.equal((await client.explore()).status,'needs_saves');
  for (const options of [{query:'q'.repeat(201)},{category:''},{category:'a'.repeat(81)},{query:'x\n'},{offset:100001},{limit:101}]) assert.throws(()=>client.searchLibrary(options),TypeError);
  for (const options of [{query:'q'.repeat(101)},{query:'x\n'},{source:'../all'},{offset:500},{limit:51}]) assert.throws(()=>client.explore(options),TypeError);
  assert.equal(requests,1);
});
