import test from 'node:test';
import assert from 'node:assert/strict';
import {syncSave, accountScope, capturePayload, reconcileRemote} from '../shared.js';

function fixture() {
  let item = {id:'local', title:'Conversation', kind:'image', image:'data:image/png;base64,YQ==', url:'', question:{id:'local'}, answer:null};
  const connection = {baseURL:'https://api.example.com',userId:'chime'};
  const calls=[];
  const remote={id:'remote',revision:1,status:'ready',features:{data_mode:'openai',question:'Why this bakery?'},suggestions:[{id:'plan',text:'Plan a visit',next_step:'Decide who to go with.'}]};
  const api={me:async()=>({user_id:'chime'}),capture:async(body,opts)=>{calls.push(['capture',body,opts]);return{id:'remote'};},waitForSave:async()=>remote,respond:async(id,body,opts)=>{calls.push(['answer',body,opts]);return{event_id:'event'};}};
  const args={id:'local',connection,api,read:async()=>structuredClone(item),update:async(_,change)=>{item=change(structuredClone(item));return structuredClone(item);}};
  return {args,calls,read:()=>item,set:value=>{item=value;}};
}

test('image-only capture has no invented URL and creates a contextual shared question', async()=>{
  const f=fixture(); const result=await syncSave(f.args);
  assert.equal(f.calls[0][1].url,''); assert.ok(f.calls[0][1].image_data);
  assert.equal(result.shared.scope,accountScope(f.args.connection));
  assert.equal(result.question.options[0].id,'plan');
  assert.equal(capturePayload({title:'Article',url:'https://example.com',contentType:'article'}).source,'article');
});
test('unknown capture outcome retains identical body and idempotency key across retry',async()=>{
  const f=fixture();let fail=true;
  f.args.api.capture=async(body,opts)=>{f.calls.push([body,opts]);if(fail){fail=false;throw Error('offline');}return{id:'remote'};};
  await assert.rejects(syncSave(f.args),/offline/);
  await syncSave(f.args);
  assert.deepEqual(f.calls[0],f.calls[1]);
});
test('uncertain answer finishes before a changed answer; successful answer is not duplicated',async()=>{
  const f=fixture();await syncSave(f.args);
  f.set({...f.read(),answer:{kind:'choice',optionId:'plan',label:'Plan a visit'}});
  let fail=true;f.args.api.respond=async(id,body,opts)=>{f.calls.push([body,opts]);if(fail){fail=false;throw Error('timeout');}};
  await assert.rejects(syncSave(f.args),/timeout/);
  f.set({...f.read(),answer:{kind:'text',label:'Maybe later'}});
  await syncSave(f.args); await syncSave(f.args);
  assert.deepEqual(f.calls[1],f.calls[2]);
  assert.deepEqual(f.calls[3][0],{action:'edit',text:'Maybe later'});
  assert.equal(f.calls.length,4);
});
test('pending upload cannot replay into a different account or server',async()=>{
  const f=fixture();await syncSave(f.args);
  f.args.connection={...f.args.connection,baseURL:'https://another.example'};
  await assert.rejects(syncSave(f.args),/another shared library/);
  f.args.connection={baseURL:'https://api.example.com',userId:'other'};
  await assert.rejects(syncSave(f.args),/account changed/);
});
test('web edits are pulled into Chrome without posting a stale local answer back',async()=>{
  const f=fixture();await syncSave(f.args);
  f.set({...f.read(),answer:{kind:'choice',optionId:'plan',label:'Plan a visit'}});
  await syncSave(f.args);
  const current=await f.args.api.waitForSave();
  f.args.api.waitForSave=async()=>({...current,responses:[{event_type:'annotation_response',occurred_at:1,payload:{action:'edit',label:'Keep for my birthday',text:'Keep for my birthday',next_step:'Saved'}}]});
  const result=await syncSave(f.args);
  assert.equal(result.answer.label,'Keep for my birthday');
  assert.equal(f.calls.filter(call=>call[0]==='answer').length,1);
});
test('basic backend rules do not replace richer local topic choices',async()=>{
  const f=fixture(); const remote=await f.args.api.waitForSave();
  f.args.api.waitForSave=async()=>({...remote,features:{data_mode:'demo_rules'}});
  const result=await syncSave(f.args);
  assert.equal(result.question.id,'local');
});

test('modern photo captures use the shared iOS/web image contract without an empty URL', async()=>{
  const f=fixture();Object.assign(f.args.connection,{modern:true,productAnalysis:true,ai:true,maxImageBytes:3145728});
  const result=await syncSave(f.args);
  const payload=f.calls[0][1];
  assert.equal(payload.url,undefined);assert.equal(payload.image_data,undefined);
  assert.equal(payload.image_data_url,f.read().image);assert.equal(result.shared.remoteId,'remote');
});
test('new AI contract uses analyze, recognizes astra and refreshes after an answer',async()=>{
  const f=fixture();Object.assign(f.args.connection,{modern:true,productAnalysis:true,ai:true});
  let remote={...await f.args.api.waitForSave(),features:{data_mode:'astra'},analysis:{summary:'A reading lamp',products:[]}};
  f.args.api.waitForSave=async()=>remote;
  f.args.api.analyzeSave=async(id,opts)=>f.calls.push(['analyze',id,opts]);
  await syncSave(f.args);
  assert.match(f.read().question.basis,/AI interpretation/);
  f.set({...f.read(),answer:{kind:'text',label:'For reading'}});
  f.args.api.respond=async()=>{remote={...remote,analysis:{summary:'A lamp for reading',products:[]}};};
  const result=await syncSave({...f.args,retryUnderstanding:true});
  assert.equal(f.calls[1][0],'analyze');
  assert.equal(result.shared.remote.analysis.summary,'A lamp for reading');
  assert.equal(result.answer.label,'For reading');
});
test('upgrade does not rewrite an uncertain legacy request under the same key',async()=>{
  const f=fixture();let fail=true;
  f.args.api.capture=async(body,opts)=>{f.calls.push([body,opts]);if(fail){fail=false;throw Error('offline');}return{id:'remote'};};
  await assert.rejects(syncSave(f.args),/offline/);
  f.args.connection.modern=true;
  await syncSave(f.args);
  assert.deepEqual(f.calls[0],f.calls[1]);assert.ok(f.calls[1][0].image_data);
});
test('definite validation rejection leaves an editable local save, not an uncertain shared upload',async()=>{
  const f=fixture();f.args.api.capture=async()=>{throw Object.assign(Error('Private URL'),{status:422});};
  await assert.rejects(syncSave(f.args),/Private URL/);
  assert.equal(f.read().shared,undefined);assert.equal(f.read().title,'Conversation');
});
test('first share runs one analysis through capture, rather than requesting a second analysis',async()=>{
  const f=fixture();Object.assign(f.args.connection,{modern:true,productAnalysis:true});
  f.args.api.analyzeSave=async()=>assert.fail('capture already schedules analysis');
  await syncSave({...f.args,retryUnderstanding:true});
});
test('a response for another saved image cannot replace this find or its prompts', async()=>{
  const f=fixture(); await syncSave(f.args);
  const before=structuredClone(f.read());
  f.args.api.waitForSave=async()=>({id:'different-photo',revision:2,title:'Hiking',suggestions:[{id:'try',text:'Try it once'}],features:{question:'Explore this activity?'}});
  await assert.rejects(syncSave(f.args),/different find/);
  assert.deepEqual(f.read(),before);
});
test('late older AI revisions cannot overwrite newer product-specific prompts',async()=>{
  const f=fixture(); await syncSave(f.args);
  const newer={...f.read().shared.remote,revision:3,features:{data_mode:'astra',question:'What interests you about this watch?'},suggestions:[{id:'design',text:'The strap and case design'}]};
  const current=reconcileRemote(f.read(),newer);
  const stale={...newer,revision:2,features:{question:'Explore this activity?'},suggestions:[{id:'try',text:'Try it once'}]};
  assert.equal(reconcileRemote(current,stale),current);
  assert.match(current.question.prompt,/watch/);
  assert.equal(capturePayload({title:'X1 Pro',url:'https://shop.example/x1',contentType:'product'},true).source,'product');
});
