import test from 'node:test';
import assert from 'node:assert/strict';
import {SyncCheck} from '../sync-check.js';

test('only fetch changed data, including deletions and completed analysis', async () => {
  const sync = new SyncCheck();
  let revision = 1, refreshes = 0;
  const options = {scope:'a', state: async () => ({user_id:'a', revision}), refresh: async () => {refreshes++;}};
  await sync.check(options); await sync.check(options);
  assert.equal(refreshes, 1);
  revision++;
  await sync.check(options);
  assert.equal(refreshes, 2);
});

test('an old account request cannot update new account sync state', async () => {
  const sync = new SyncCheck();
  let release;
  const pending = sync.check({scope:'a', state: () => new Promise(resolve => {release = resolve;}), refresh: () => assert.fail('old data fetched')});
  sync.reset();
  await sync.check({scope:'b', state: async () => ({user_id:'b', revision:2}), refresh: async () => {}});
  release({user_id:'a', revision:9});
  await pending;
  assert.equal(sync.revision, 2);
});

test('reject mismatched identity and back off failures without losing a change', async () => {
  const sync = new SyncCheck();
  await assert.rejects(sync.check({scope:'a', state: async () => ({user_id:'b', revision:2}), refresh: () => assert.fail(), now:100}), /account changed/);
  assert.equal(sync.revision, null);
  assert.equal(sync.retryAt, 15100);
  let attempts = 0;
  const options = {scope:'a', state: async () => ({user_id:'a', revision:2}), refresh: async () => {attempts++;}};
  await sync.check({...options, now:200});
  assert.equal(attempts, 0);
  await sync.check({...options, now:15100});
  assert.equal(attempts, 1);
  assert.equal(sync.retryAt, 0);
});

test('an unsuccessful data refresh does not acknowledge the remote revision', async () => {
  const sync = new SyncCheck();
  await assert.rejects(sync.check({scope:'a', state: async () => ({user_id:'a', revision:3}), refresh: async () => {throw new Error('offline');}}));
  assert.equal(sync.revision, null);
});
