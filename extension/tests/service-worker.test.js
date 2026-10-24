import test from 'node:test';
import assert from 'node:assert/strict';

test('service worker keeps state mutations responsive during a save and restricts their callers', async t => {
  const priorChrome = globalThis.chrome, priorFetch = globalThis.fetch;
  const settings = {baseURL:'https://old.example.com'}, session = {};
  const extensionOrigin = 'chrome-extension://fixture/';
  let listener, permitted = true, requestStarted, resolveRequest;
  const started = new Promise(resolve => {requestStarted = resolve;});
  const pendingResponse = new Promise(resolve => {resolveRequest = resolve;});
  function area(values) {
    return {
      get:async keys => structuredClone(Object.fromEntries((Array.isArray(keys) ? keys : [keys]).map(key => [key, values[key]]))),
      set:async update => {Object.assign(values, structuredClone(update));},
      remove:async keys => {for (const key of Array.isArray(keys) ? keys : [keys]) delete values[key];},
      setAccessLevel:async () => {}
    };
  }
  globalThis.chrome = {
    storage:{local:area(settings), session:area(session)},
    runtime:{id:'fixture', getURL:path => extensionOrigin + path,
      onMessage:{addListener:handler => {listener = handler;}},
      onInstalled:{addListener:() => {}}, onStartup:{addListener:() => {}}},
    permissions:{contains:async () => permitted}
  };
  globalThis.fetch = async (url, options) => {
    assert.equal(url, 'https://old.example.com/v1/saves');
    assert.equal(options.headers.Authorization, 'Bearer old-account');
    requestStarted();
    return pendingResponse;
  };
  t.after(() => {globalThis.chrome = priorChrome; globalThis.fetch = priorFetch;});
  await import('../service-worker.js');
  function message(body, page = 'popup.html', id = 'fixture') {
    return new Promise(resolve => {
      const handled = listener(body, {id, url:extensionOrigin + page}, resolve);
      if (!handled) resolve(undefined);
    });
  }

  for (const type of ['capture:draft', 'capture:reset', 'capture:save', 'capture:backend']) {
    assert.equal(await message({type}, 'content-script.html'), undefined);
    assert.equal(await message({type}, 'popup.html', 'another-extension'), undefined);
  }
  assert.equal(await message({type:'capture:backend'}, 'popup.html'), undefined);
  assert.equal(await message({type:'capture:save'}, 'options.html'), undefined);

  permitted = false;
  const denied = await message({type:'capture:backend', baseURL:'https://new.example.com'}, 'options.html');
  assert.equal(denied.ok, false);
  assert.equal(settings.baseURL, 'https://old.example.com');
  permitted = true;

  const payload = {url:'https://product.example/watch',title:'A watch',note:'Old note',selected_text:''};
  const draft = await message({type:'capture:draft',baseURL:settings.baseURL,payload});
  const save = message({type:'capture:save',baseURL:settings.baseURL,token:'old-account',payload,draftRevision:draft.result.revision});
  await started;
  const switched = await message({type:'capture:backend',baseURL:'https://new.example.com'}, 'options.html');
  assert.equal(switched.ok, true, 'settings can change while the network request remains pending');
  const newer = await message({type:'capture:draft',baseURL:settings.baseURL,payload:{...payload,note:'New note'}});
  assert.equal(newer.ok, true);
  const current = structuredClone(session);
  resolveRequest(new Response(JSON.stringify({id:'old-save',status:'pending',duplicate:false}), {headers:{'Content-Type':'application/json'}}));
  assert.equal((await save).ok, true);
  assert.deepEqual(session, current, 'old response cannot change the current workspace or draft');
  assert.equal(session.captureDraft.note, 'New note');
  assert.equal(session.saveAttempt, undefined);
  assert.equal(session.auth, undefined);
});
