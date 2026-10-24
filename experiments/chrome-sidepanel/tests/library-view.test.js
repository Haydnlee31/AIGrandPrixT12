import test from 'node:test';
import assert from 'node:assert/strict';
import {mergeLibrary,remoteSave,catalogImage} from '../library-view.js';
import {accountScope,reconcileRemote} from '../shared.js';
import {imageBytes,sharedImage} from '../shared-image.js';
import {PagedFeed} from '../lib/feed.js';
import {loadSavedLibrary} from '../lib/library.js';
import {offerLink,priceText} from '../lib/presentation.js';
const connection={baseURL:'https://mynah-finds.vercel.app',userId:'one'};
const remote={id:'server',title:'Chair',captured_at:100,status:'ready',suggestions:[],features:{},responses:[]};
const local={id:'local',title:'Offline',createdAt:new Date(0).toISOString()};

test('library merges server finds once and hides deletions and other account caches',()=>{
  const mirror={...remoteSave(remote,connection),id:'local-mirror',image:'original'};
  const other={...mirror,id:'other',shared:{...mirror.shared,scope:'other-account'}};
  const merged=mergeLibrary([local,mirror,other],[remote],connection);
  assert.equal(merged.length,2);assert.equal(merged[0].image,'original');
  assert.deepEqual(mergeLibrary([local,mirror,other],[],connection),[local]);
  assert.deepEqual(mergeLibrary([local,mirror,other],null,null),[local]);
  assert.equal(mergeLibrary([mirror],null,connection).length,1);
});
test('remote answer is read without posting it back, but pending local edits survive refresh',()=>{
  const event={event_type:'annotation_response',occurred_at:101,payload:{action:'edit',text:'A gift'}};
  const item=remoteSave({...remote,responses:[event]},connection);
  assert.equal(item.answer.label,'A gift');assert.ok(item.shared.answerAttempt.done);
  const changed={...item,answer:{kind:'text',label:'For my desk'}};
  assert.equal(reconcileRemote(changed,{...remote,responses:[event]}).answer.label,'For my desk');
  assert.equal(item.shared.scope,accountScope(connection));
});
test('private images do not go to catalog hosts and catalog URLs cannot contain credentials',()=>{
  assert.equal(catalogImage('https://evil.test/img'),null);
  assert.equal(catalogImage('https://x:secret@amazon-berkeley-objects.s3.us-east-1.amazonaws.com/img'),null);
  assert.equal(catalogImage('https://amazon-berkeley-objects.s3.us-east-1.amazonaws.com/images/a.jpg'),'https://amazon-berkeley-objects.s3.us-east-1.amazonaws.com/images/a.jpg');
});
test('image size counts base64 padding and rejects unsupported formats',async()=>{
  assert.equal(imageBytes('data:image/png;base64,YQ=='),1);
  assert.equal(await sharedImage('data:image/png;base64,YQ==',4),'data:image/png;base64,YQ==');
  assert.throws(()=>imageBytes('data:image/svg+xml;base64,YQ=='),/PNG/);
});
test('library pagination deduplicates and fails rather than silently truncating a repeated cursor',async()=>{
  const pages=[{items:[{id:'a'}],next_offset:100},{items:[{id:'a'},{id:'b'}],next_offset:null}];
  assert.deepEqual(await loadSavedLibrary({collection:async()=>pages.shift()}),[{id:'a'},{id:'b'}]);
  await assert.rejects(loadSavedLibrary({collection:async()=>({items:[],next_offset:0})}),/finish loading/);
});
test('late search and disconnected account responses cannot replace the current feed',async()=>{
  const feed=new PagedFeed();let finish;
  const old=feed.load(()=>new Promise(resolve=>{finish=resolve;}));
  await feed.load(async()=>({items:[{id:'new'}],next_offset:null}));
  finish({items:[{id:'old'}],next_offset:null});await old;
  assert.deepEqual(feed.items,[{id:'new'}]);
  const pending=feed.load(()=>new Promise(resolve=>{finish=resolve;}));feed.clear();
  finish({items:[{id:'private'}],next_offset:null});await pending;
  assert.deepEqual(feed.items,[]);
});
test('historical catalog prices never become live offer links',()=>{
  assert.equal(priceText(null,'USD'),'Price unavailable');
  assert.equal(offerLink({product:{data_kind:'licensed_dataset',offer:{url:'https://shop.test',price_minor:1000,currency:'USD'}},action:'view_offer',action_url:'https://shop.test'}),null);
});
