import test from 'node:test';
import assert from 'node:assert/strict';
import {syncSave, accountScope, capturePayload, sharedQuestion} from '../shared.js';
import {applyAnswer, createSave} from '../questions.js';

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
  f.set(applyAnswer(f.read(), {optionId:'plan'}));
  let fail=true;f.args.api.respond=async(id,body,opts)=>{f.calls.push([body,opts]);if(fail){fail=false;throw Error('timeout');}};
  await assert.rejects(syncSave(f.args),/timeout/);
  f.set(applyAnswer(f.read(), {text:'Maybe later'}));
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
  f.set(applyAnswer(f.read(), {optionId:'plan'}));
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

test('new connections use the unified image field, but uncertain legacy uploads retain their exact body', async () => {
  const f = fixture(); let failed = false;
  f.args.api.capture = async (body, options) => { f.calls.push([body, options]); if (!failed) { failed = true; throw Error('lost response'); } return {id: 'remote'}; };
  await assert.rejects(syncSave(f.args), /lost response/);
  f.args.connection.imageField = 'image_data_url';
  await syncSave(f.args);
  assert.deepEqual(f.calls[0], f.calls[1]);
  assert.ok(f.calls[1][0].image_data);
  const body = capturePayload({title: 'Image', image: 'data:image/png;base64,YQ=='}, f.args.connection);
  assert.ok(body.image_data_url); assert.equal(body.url, undefined); assert.equal(body.image_data, undefined);
});

test('Astra actions follow a why question and are labelled as AI', async () => {
  const f = fixture();
  f.set(createSave({kind: 'page', title: 'How Now Brown Bird?', url: 'https://www.nparks.gov.sg/publications-resources/articles/how-now-brown-bird'}));
  f.args.api.waitForSave = async () => ({id: 'remote', revision: 1, status: 'ready', features: {data_mode: 'astra', subject: 'Birdwatching binoculars'}, suggestions: [{id: 'compare', kind: 'intent', claim: 'compare_options', text: 'Compare similar products'}]});
  let result = await syncSave(f.args);
  assert.equal(result.question.id, 'birdwatching-v1');
  f.set(applyAnswer(result, {optionId: 'gear'}));
  result = await syncSave(f.args);
  assert.equal(result.question.phase, 'action');
  assert.match(result.question.basis, /AI interpretation/);
  assert.equal(f.calls.find(call => call[0] === 'answer')[1].text, 'Explore binoculars for birdwatching');
});

test('several local intents sync once each and remote active intents remain visible', async () => {
  const f = fixture();
  let local = createSave({kind:'page', title:'Small room ideas', url:'https://example.org/room'});
  local = applyAnswer(local, {optionId:'lighting'});
  local = applyAnswer(local, {optionId:'layout'});
  f.set(local);
  const events = [];
  f.args.api.respond = async (_, payload) => {
    f.calls.push(['answer', payload]);
    const event = {id:`event-${events.length}`, event_type:'annotation_response', active:true, occurred_at:events.length + 1, payload}; events.push(event);
    return {event_id:event.id};
  };
  const remote = await f.args.api.waitForSave();
  f.args.api.waitForSave = async () => ({...remote, responses: structuredClone(events)});
  let result = await syncSave(f.args);
  assert.equal(result.intents.length, 2);
  assert.equal(result.pendingAnswers.length, 0);
  await syncSave(f.args);
  assert.equal(f.calls.filter(call => call[0] === 'answer').length, 2);
  events[0].active = false;
  result = await syncSave(f.args);
  assert.equal(result.intents.length, 1);
  assert.equal(result.intents[0].label, 'The layout or storage');
});
