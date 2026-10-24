/** Actual side-panel controller + bundled SDK against an explicitly configured isolated API. */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {CommonThreadClient} from '../lib/client.js';
import {syncSave, accountScope} from '../shared.js';
import {correctTranscript, searchableFind} from '../multimodal.js';
import {createSave} from '../questions.js';

const baseURL = process.env.MYMAH_TEST_API_URL;
const token = process.env.MYMAH_TEST_ACCOUNT_TOKEN;
const audioFile = process.env.MYMAH_TEST_VOICE_WAV;
if (!baseURL || !token || !audioFile) throw new Error('Set MYMAH_TEST_API_URL, MYMAH_TEST_ACCOUNT_TOKEN and MYMAH_TEST_VOICE_WAV for an isolated synthetic-fixture account.');
const api = new CommonThreadClient({baseURL, token});
const [identity, capabilities] = await Promise.all([api.me(), api.multimodalCapabilities()]);
assert.equal(capabilities.enabled, true, 'The tested backend must have MULTIMODAL_ENABLED=true');
const connection = {baseURL: api.baseURL, token, userId: identity.user_id, multimodal: true, modern: true, productAnalysis: true, ai: true};
const png = await readFile(new URL('./demo-image.png', import.meta.url));
const audio = await readFile(audioFile);
let item = {...createSave({kind: 'image', title: 'Shopping inspiration', image: `data:image/png;base64,${png.toString('base64')}`, note: 'A gift idea. I want to compare options.'}),
  audio: `data:audio/wav;base64,${audio.toString('base64')}`};
const args = {id: item.id, connection, api, read: async () => structuredClone(item), update: async (_, change) => {item = change(structuredClone(item)); return structuredClone(item);}};
const checks = [];
let deleted = false;
try {
  await syncSave(args);
  assert.equal(item.shared.scope, accountScope(connection));
  assert.equal(item.shared.remoteId, undefined, 'Voice publication requires review');
  assert.equal(item.shared.mm.capture.status, 'ready');
  assert.ok(item.shared.mm.capture.assets.some(asset => asset.kind === 'audio' && asset.transcript));
  checks.push('actual_capture_upload_audio_analysis', 'explicit_voice_review');
  await correctTranscript({...args, text: 'This is a birthday gift. Please avoid bright red.'});
  await syncSave({...args, retryUnderstanding: true});
  assert.match(item.shared.mm.capture.assets.find(asset => asset.kind === 'audio').transcript, /birthday gift/);
  checks.push('corrected_transcript_reanalysis');
  await syncSave({...args, publish: true});
  assert.ok(item.shared.remoteId);
  assert.equal(item.shared.remote.status, 'ready');
  assert.ok(item.shared.remote.analysis);
  assert.equal(item.shared.remote.features.multimodal_preview.schema_version, 2);
  assert.match(searchableFind(item), /birthday/);
  checks.push('shared_library_publication', 'contextual_preview_display_model');
  const savedId = item.shared.remoteId;
  const results = await api.searchLibrary({query:'birthday gift'});
  assert.ok(results.items.some(result => (result.id || result.item?.id || result.saved_item?.id) === savedId), 'Reviewed voice must be searchable');
  checks.push('voice_library_search');
  item.answer = {kind: 'text', label: 'I prefer muted colours for this gift.'};
  await syncSave(args);
  assert.ok(item.shared.answerAttempt.done);
  const explore = await api.explore();
  assert.ok(Array.isArray(explore.items));
  checks.push('annotation_reanalysis', 'explore_contract');
  // Reloading the controller uses the persisted item and does not republish.
  await syncSave(args);
  assert.equal(item.shared.remoteId, savedId);
  checks.push('durable_resume_without_duplicate');
  await api.deleteSave(savedId, {idempotencyKey: crypto.randomUUID()});
  deleted = true;
  await assert.rejects(api.getSave(savedId), error => [404,410].includes(error.status));
  await assert.rejects(api.getMultimodalCapture(item.shared.mm.captureId), error => [404,410].includes(error.status));
  checks.push('delete_shared_save_and_media');
  process.stdout.write(JSON.stringify({status:'passed', checks}, null, 2) + '\n');
} finally {
  if (!deleted && item.shared?.remoteId) await api.deleteSave(item.shared.remoteId, {idempotencyKey:crypto.randomUUID()}).catch(() => {});
  else if (!deleted && item.shared?.mm?.captureId) await api.deleteMultimodalCapture(item.shared.mm.captureId, {idempotencyKey:crypto.randomUUID()}).catch(() => {});
}
