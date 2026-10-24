import test from 'node:test';
import assert from 'node:assert/strict';
import {PendingCaptureStore} from '../pending.mjs';
const memory = () => {const data = new Map(); return {getItem:key=>data.get(key), setItem:(key,value)=>data.set(key,value), removeItem:key=>data.delete(key)};};
test('capture survives restart and account switching with its original body and key', () => {
  const storage=memory(), first=new PendingCaptureStore(()=>storage);
  const attempt={accountId:'alice',key:'retry-1',payload:{url:'https://example.com/lamp'}};
  first.put(attempt);
  const restarted=new PendingCaptureStore(()=>storage);
  assert.equal(restarted.get('bob'),null);
  assert.deepEqual(restarted.get('alice'),attempt);
  restarted.put({...attempt,key:'retry-2'});
  restarted.remove(attempt);
  assert.equal(restarted.get('alice').key,'retry-2');
});
test('storage failure stops submission instead of losing a durable retry', () => {
  const pending=new PendingCaptureStore(()=>({setItem:()=>{throw Error('quota');}}));
  assert.throws(()=>pending.put({accountId:'alice',key:'retry-1',payload:{}}),/retry copy/);
});
