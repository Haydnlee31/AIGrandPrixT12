import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {normalizeBackendURL, backendPermission, capturePayload, validatePageURL, requestFingerprint, readableError} from '../platform.js';

const payload = {url:'https://www.pinterest.com/pin/123', title:'A warm reading corner', selected_text:'Linen and wood', note:''};

test('backend origins permit loopback HTTP and require HTTPS elsewhere', () => {
  assert.equal(normalizeBackendURL(' http://localhost:8001/ '), 'http://localhost:8001');
  assert.equal(normalizeBackendURL('https://API.EXAMPLE.COM/'), 'https://api.example.com');
  for (const value of ['http://example.com', 'https://example.com/v1', 'https://token@example.com', 'https://example.com?token=a', 'https://example.com/#secret', 'file:///etc/passwd', 'https://*.example.com']) {
    assert.throws(() => normalizeBackendURL(value));
  }
});

test('permission request covers the configured scheme, host and port', () => {
  assert.equal(backendPermission('https://api.example.com'), 'https://api.example.com:443/*');
  assert.equal(backendPermission('https://api.example.com:8443'), 'https://api.example.com:8443/*');
  assert.equal(backendPermission('http://localhost:8001'), 'http://localhost:8001/*');
});

test('capture attributes client independently of source and ignores unknown fields', () => {
  assert.deepEqual(capturePayload({...payload, token:'do-not-send', client:'web'}), {...payload, source:'pinterest', client:'chrome_extension'});
  assert.equal(capturePayload({...payload, url:'https://pinterest.com.evil.example/a'}).source, 'web');
  assert.equal(capturePayload({...payload, url:'https://www.instagram.com/p/abc'}).source, 'instagram');
});

test('capture rejects unsupported pages and oversized inputs', () => {
  for (const value of ['chrome://settings', 'file:///tmp/doc', 'http://localhost:8000', 'https://name:secret@example.com/a', 'https://example.com/' + 'a'.repeat(2048)]) {
    assert.throws(() => validatePageURL(value));
  }
  assert.throws(() => capturePayload({...payload, title:' '}));
  assert.throws(() => capturePayload({...payload, note:'a'.repeat(2001)}));
  assert.throws(() => capturePayload({...payload, selected_text:'a'.repeat(12001)}));
});

test('retry identity changes with workspace, token, and payload', async () => {
  const first = await requestFingerprint('https://api.example.com', 'token', payload);
  assert.match(first, /^[0-9a-f]{64}$/);
  assert.equal(first, await requestFingerprint('https://api.example.com/', 'token', payload));
  for (const tuple of [
    ['https://second.example.com', 'token', payload],
    ['https://api.example.com', 'other-token', payload],
    ['https://api.example.com', 'token', {...payload,note:'New intent'}]
  ]) assert.notEqual(first, await requestFingerprint(...tuple));
});

test('errors preserve request correlation and deletion invalidation guidance', () => {
  assert.match(readableError({message:'Try again', requestId:'req-123'}), /req-123/);
  assert.match(readableError({code:'mutation_expired'}), /invalidated by a deletion/);
});

test('manifest uses bundled code, opt-in active tab, and optional remote hosts', async () => {
  const manifest = JSON.parse(await readFile(new URL('../manifest.json', import.meta.url), 'utf8'));
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.background.type, 'module');
  assert.deepEqual(manifest.permissions, ['activeTab', 'scripting', 'storage']);
  assert.deepEqual(manifest.host_permissions, ['http://127.0.0.1:8000/*']);
  assert.ok(manifest.optional_host_permissions.includes('https://*/*'));
  assert.equal(manifest.content_scripts, undefined);
  assert.equal(manifest.externally_connectable, undefined);
  for (const file of [manifest.background.service_worker, manifest.action.default_popup, manifest.options_page]) {
    assert.ok((await readFile(new URL('../' + file, import.meta.url), 'utf8')).length);
  }
});
