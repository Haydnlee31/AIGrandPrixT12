import test from 'node:test';
import assert from 'node:assert/strict';
import {sessionToken} from '../login.js';

const jwt = subject => 'header.'+btoa(JSON.stringify({sub:subject}))+'.signature';
test('a browser account switch between session lookup and token issuance cannot upload to the new account', async () => {
  const token = sessionToken({baseURL:'https://mynah.example', subject:'alice', stillConnected:async()=>true,
    request:async (_url, path)=>path.startsWith('get-session') ? {user:{id:'alice'}} : {token:jwt('bob')}});
  await assert.rejects(token, /sign-in changed/);
});
test('disconnect during token issuance prevents use of the old connection', async () => {
  let connected = true;
  const token = sessionToken({baseURL:'https://mynah.example', subject:'alice', stillConnected:async()=>connected,
    request:async (_url, path)=>{
      if(path.startsWith('get-session')) return {user:{id:'alice'}};
      connected=false; return {token:jwt('alice')};
    }});
  await assert.rejects(token, /sign in again/);
});
test('fresh short-lived tokens are retrieved without persisting credentials', async () => {
  const token = sessionToken({baseURL:'https://mynah.example', subject:'alice', stillConnected:async()=>true,
    request:async (_url, path)=>path.startsWith('get-session') ? {user:{id:'alice'}} : {token:jwt('alice')}});
  assert.equal(await token(), jwt('alice'));
});
