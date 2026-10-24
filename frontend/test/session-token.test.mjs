import test from 'node:test';
import assert from 'node:assert/strict';
import {sessionToken} from '../session-token.mjs';
const tokenFor = sub => `header.${btoa(JSON.stringify({sub}))}.signature`;
test('parallel library requests share one session/token exchange and later batches recheck', async () => {
  let sessions=0, issues=0;
  const token=sessionToken({subject:'alice',isCurrent:()=>true,onExpired:()=>{},
    session:async()=>{sessions++;return {user:{id:'alice'}};},
    issueToken:async()=>{issues++;return {token:tokenFor('alice')};}});
  assert.deepEqual(await Promise.all([token(),token(),token()]),Array(3).fill(tokenFor('alice')));
  assert.equal(sessions,1);assert.equal(issues,1);
  await token();assert.equal(sessions,2);
});
test('failed refresh can recover, but a changed account cannot reuse its result', async () => {
  let fail=true, current=true;
  const token=sessionToken({subject:'alice',isCurrent:()=>current,onExpired:()=>{},
    session:async()=>{if(fail)throw Error('temporary outage');return {user:{id:'alice'}};},
    issueToken:async()=>{current=false;return {token:tokenFor('alice')};}});
  await assert.rejects(token(),/temporary outage/);
  fail=false;await assert.rejects(token(),/sign in again/);
});
test('switching accounts between session lookup and token issuance rejects the token', async () => {
  const token=sessionToken({subject:'alice',isCurrent:()=>true,onExpired:()=>{},
    session:async()=>({user:{id:'alice'}}),issueToken:async()=>({token:tokenFor('bob')})});
  await assert.rejects(token(),/account changed/);
});
