import test from 'node:test';
import assert from 'node:assert/strict';
import {syncSave, accountScope, capturePayload} from '../shared.js';

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
