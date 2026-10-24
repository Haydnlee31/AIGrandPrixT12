import {SyncCheck} from "./sync-check.js";
import {startLogin} from './login.js';
import { capturePage, importImage } from './capture.js';
import { addSave, listSaves, getSave, updateSave, saveAnswer, deleteSave } from './storage.js';
import { safeUrl } from './questions.js';
import { connect, disconnect, getConnection, inspectConnection, sync, removeShared } from './connection.js';

import {CommonThreadClient} from './lib/client.js';
import {loadSavedLibrary} from './lib/library.js';
import {mergeLibrary} from './library-view.js';
import {reconcileRemote} from './shared.js';
import {createExplore, renderInsights} from './intelligence.js';

const $ = selector => document.querySelector(selector);
const detail = $('#detail');
let items = [];
let selectedId;
let busy = false;
let editing = false;
let uploadType = '';
let contextRevision;
let refreshPending = false;
let connection = null;
let remoteItems = null;
let connectionRevision = 0;
let libraryController;
let imageController;
let imageURL;
let view = 'library';
let lastPull = 0;
const autoSync = new SyncCheck();
const client = () => new CommonThreadClient(connection);
const explore = createExplore({client, connection: () => connection,
  openSettings: () => $('#settings-dialog').showModal(),
  openFind: id => run(async () => {
    await pullLibrary();
    const item = items.find(item => item.shared?.remoteId === id);
    if (!item) throw new Error('This find was removed. Refresh Explore for current recommendations.');
    selectedId = item.id; showView('library'); render(); detail.scrollIntoView({block: 'start'});
  })});
function showView(next) {
  view = next;
  $('#status').textContent = '';
  $('#error').hidden = true;
  $('#library-view').hidden = next !== 'library';
  $('#explore-view').hidden = next !== 'explore';
  $('#library-tab').setAttribute('aria-pressed', String(next === 'library'));
  $('#explore-tab').setAttribute('aria-pressed', String(next === 'explore'));
  if (next === 'explore') explore.load();
  window.scrollTo({top: 0});
}
function clearImage() {
  imageController?.abort();
  if (imageURL) URL.revokeObjectURL(imageURL);
  imageURL = null;
}
async function hydrateImage(item, image) {
  if (item.image || !item.shared?.remote?.has_image || !connection) return;
  const revision = connectionRevision;
  imageController = new AbortController();
  try {
    const response = await fetch(new URL(`/v1/saves/${encodeURIComponent(item.shared.remoteId)}/image`, connection.baseURL),
      {headers: {Authorization: `Bearer ${typeof connection.token === 'function' ? await connection.token() : connection.token}`}, cache: 'no-store', redirect: 'error',
        signal: AbortSignal.any([imageController.signal, AbortSignal.timeout(15000)])});
    if (!response.ok || !/^image\/(jpeg|png|webp)(;|$)/i.test(response.headers.get('content-type') || '')) throw new Error('Image unavailable');
    const blob = await response.blob();
    if (revision !== connectionRevision || !image.isConnected) return;
    imageURL = URL.createObjectURL(blob); image.src = imageURL; image.hidden = false;
  } catch (error) {
    if (revision === connectionRevision && image.isConnected && error.name !== 'AbortError') {
      const message = element('p', 'field-help', 'Image unavailable right now. Refresh this find to try again.'); image.after(message);
    }
  }
}
async function ensureLocal(id) {
  const item = items.find(item => item.id === id);
  if (!item) throw new Error('This find is no longer in this library.');
  if (await getSave(id)) {
    if (item.shared?.remote) await updateSave(id, current => reconcileRemote(current, item.shared.remote));
  }
  else await addSave({...item, remoteOnly: false});
}
async function pullLibrary() {
  if (!connection) return refresh();
  libraryController?.abort();
  const controller = libraryController = new AbortController();
  const revision = connectionRevision;
  $('#library-status').textContent = 'Syncing shared finds…';
  try {
    const records = await loadSavedLibrary(client(), {signal: controller.signal});
    if (revision !== connectionRevision || controller.signal.aborted) return;
    remoteItems = records; lastPull = Date.now();
    $('#library-status').textContent = 'Shared library up to date';
    await refresh();
  } catch (error) {
    if (revision !== connectionRevision || error.name === 'AbortError') return;
    $('#library-status').textContent = 'Could not refresh shared finds. Your local copies are safe.';
    throw error;
  }
}

const kindLabel = { page: 'Saved page', screenshot: 'Screenshot', image: 'Uploaded image' };
const channel = new BroadcastChannel('saved-shopping');

function labelFor(item) {
  if (item.contentType === 'conversation') return 'Conversation screenshot';
  if (item.contentType === 'selected-image') return 'Saved image';
  if (item.contentType === 'social' && item.kind === 'page') return 'Social post';
  return kindLabel[item.kind];
}

function element(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined) el.textContent = text;
  return el;
}

function showError(error) {
  const target = $('#settings-dialog').open ? $('#connection-error') : $('#error');
  target.textContent = error.message?.includes('Private addresses are not supported') ? 'Saved on this device. The shared library does not accept local or private page URLs. Upload the image on its own to share it.' : error.message || 'Something went wrong. Please try again.';
  target.hidden = false;
}

async function run(work) {
  if (busy) return;
  busy = true;
  $('#error').hidden = true;
  $('#connection-error').hidden = true;
  document.querySelectorAll('button:not(.close-find):not(#close-product):not(#close-settings), input, textarea').forEach(control => { control.disabled = true; });
  try { await work(); }
  catch (error) { $('#status').textContent = ''; showError(error); }
  finally { busy = false; document.querySelectorAll('button:not(.close-find):not(#close-product):not(#close-settings), input, textarea').forEach(control => { control.disabled = false; }); if (refreshPending) { refreshPending = false; syncContext().catch(showError); } }
}

async function refresh() {
  const revision = connectionRevision;
  const local = await listSaves();
  if (revision !== connectionRevision) return;
  items = mergeLibrary(local, remoteItems, connection);
  if (!items.some(item => item.id === selectedId)) { selectedId = undefined; editing = false; }
  render();
}

function render() {
  $('.local-badge').textContent = connection ? (connection.ai ? 'Connected · AI suggestions' : 'Connected · Basic suggestions') : 'On this device · Basic suggestions';
  $('.collection').hidden = Boolean(selectedId);
  $('#count').textContent = `${items.length} ${items.length === 1 ? 'save' : 'saves'}`;
  const library = $('#library');
  library.replaceChildren();
  if (!items.length) {
    const empty = element('div', 'empty');
    const bird = element('img'); bird.src = 'icons/icon-128.png'; bird.alt = '';
    empty.append(bird, element('h3', '', 'A home for your finds.'), element('p', '', 'An idea. A lovely object. Something for later. Save your first page above.'));
    library.append(empty);
  }
  const query = $('#library-query').value.trim().toLocaleLowerCase();
  const visible = items.filter(item => [item.title, item.note, item.excerpt, item.shared?.remote?.analysis?.summary].join(' ').toLocaleLowerCase().includes(query));
  if (items.length && !visible.length) library.append(element('p', 'field-help', 'No finds match your search.'));
  for (const item of visible) {
    const button = element('button', 'library-item');
    button.setAttribute('aria-pressed', String(item.id === selectedId));
    const thumb = item.image ? element('img', 'thumbnail') : document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    if (!item.image) { thumb.setAttribute('class', 'thumbnail-symbol'); thumb.setAttribute('viewBox', '0 0 24 24'); thumb.setAttribute('aria-hidden', 'true'); const path = document.createElementNS('http://www.w3.org/2000/svg', 'path'); path.setAttribute('d', 'M6 4h12v17l-6-4-6 4z'); thumb.append(path); }
    if (item.image) { thumb.src = item.image; thumb.alt = ''; }
    const copy = element('span', 'item-copy');
    const context = !item.answer ? 'Add context' : item.answer.kind === 'skipped' ? 'For later' : 'Context saved';
    copy.append(element('span', 'item-title', item.title), element('span', 'item-meta', `${labelFor(item)} · ${context}`));
    const arrow = element('span', 'item-arrow', '›'); arrow.setAttribute('aria-hidden', 'true');
    button.append(thumb, copy, arrow);
    button.addEventListener('click', () => { if (busy) return; selectedId = item.id; editing = false; $('#status').textContent = ''; $('#error').hidden = true; render(); detail.querySelector('.back-to-library').focus(); detail.scrollIntoView({ block: 'start' }); });
    library.append(button);
  }
  renderDetail(items.find(item => item.id === selectedId));
}

function renderDetail(item) {
  clearImage();
  detail.replaceChildren();
  detail.hidden = !item;
  if (!item) return;
  detail.append($('#detail-template').content.cloneNode(true));
  const find = selector => detail.querySelector(selector);
  find('.saved-title').textContent = item.title;
  find('.kind-badge').textContent = labelFor(item);
  if (item.image) { find('.hero-image').src = item.image; find('.hero-image').hidden = false; }
  hydrateImage(item, find('.hero-image'));
  renderInsights(find('.insights'), item.shared?.remote, query => {showView('explore'); explore.search(query);});
  const source = safeUrl(item.url);
  if (source) find('.source-link').href = source;
  else find('.source-link').hidden = true;
  if (item.note) { find('.saved-note').textContent = item.note; find('.saved-note').hidden = false; }
  if (item.excerpt) { find('.source-text').hidden = false; find('.source-text p').textContent = item.excerpt; }
  find('.sync-state').textContent = item.shared ? `Shared library · ${item.shared.remote?.status === 'ready' ? 'Saved' : item.shared.remote?.status === 'enrichment_failed' ? 'Saved; understanding failed' : 'Waiting to finish syncing'}` : 'Saved on this device';
  if (item.shared?.duplicate) find('.sync-state').textContent += ' · Already saved; original details kept';
  find('.sync-save').textContent = !connection ? 'Connect for AI suggestions' : item.shared ? (connection.productAnalysis ? 'Refresh AI insights' : 'Refresh / retry sync') : connection.ai ? 'Get AI suggestions for this find' : 'Share with library';
  find('.sync-save').addEventListener('click', () => {
    if (!connection) { $('#connection-error').hidden = true; $('#settings-dialog').showModal(); }
    else run(() => share(item.id, true));
  });
  const features = item.shared?.remote?.features;
  if (!item.shared?.remote?.analysis && !features?.analysis && features?.summary) { find('.understanding').hidden = false; find('.understanding').textContent = `${['openai', 'astra'].includes(features.data_mode) ? 'AI interpretation: ' : ''}${features.summary}`; }
  for (const evidence of features?.evidence || []) {
    find('.content-evidence').hidden = false;
    find('.content-evidence').append(element('li', '', `${evidence.text} — ${evidence.source === 'image' ? 'AI reading of image; check against the original' : 'Quote from saved content; not independently verified'}`));
  }
  const showQuestion = !item.answer || editing;
  find('.question-block').hidden = !showQuestion;
  find('.answer-block').hidden = showQuestion;
  find('.question-title').textContent = item.question.prompt;
  const aiQuestion = item.question.engine === 'shared' && (['openai', 'astra'].includes(features?.data_mode) || Boolean(item.shared?.remote?.analysis));
  find('.question-mode').textContent = aiQuestion ? 'AI suggestions for this saved find' : 'Basic suggestions from saved text only. Image contents have not been analysed for these prompts.';
  find('.question-basis').textContent = `Suggested from ${item.question.basis}. Choose what fits, or skip.`;
  if (item.imageCapture === 'visible-crop') { find('.capture-quality').hidden = false; find('.capture-quality').textContent = 'Saved the visible part of this image. The site did not allow copying the original.'; }
  for (const choice of item.question.options) {
    const button = element('button', 'choice', choice.label);
    button.addEventListener('click', () => answer(item.id, { optionId: choice.id }));
    find('.choices').append(button);
  }
  find('.answer-form').addEventListener('submit', event => { event.preventDefault(); answer(item.id, { text: find('#own-answer').value }); });
  find('.skip').addEventListener('click', () => answer(item.id, { skip: true }));
  if (item.answer) {
    find('.answer-label').textContent = item.answer.label;
    find('.answer-next').textContent = item.answer.next;
    if (item.answer.kind === 'skipped') find('.answer-block .answer-status').textContent = 'Kept for later';
    if (item.answer.kind === 'text') find('#own-answer').value = item.answer.label;
  }
  find('.edit-answer').addEventListener('click', () => { editing = true; renderDetail(item); find('.choice')?.focus({preventScroll: true}); detail.scrollIntoView({block: 'start'}); });
  const closeFind = () => { selectedId = undefined; editing = false; $('#status').textContent = ''; render(); const first = $('#library .library-item'); if (first) first.focus({preventScroll: true}); window.scrollTo({top: 0}); };
  find('.back-to-library').addEventListener('click', closeFind);
  find('.close-find').addEventListener('click', closeFind);
  find('.delete').addEventListener('click', event => {
    if (event.currentTarget.dataset.confirm !== 'yes') {
      event.currentTarget.dataset.confirm = 'yes';
      event.currentTarget.textContent = 'Confirm remove';
      event.currentTarget.setAttribute('aria-label', 'Confirm remove this save');
      return;
    }
    run(async () => { await ensureLocal(item.id); await removeShared(item.id); await deleteSave(item.id); selectedId = undefined; editing = false; if (connection) await pullLibrary(); else await refresh(); explore.reset(); channel.postMessage('changed'); $('#status').textContent = item.shared ? 'Removed from your device and shared library.' : 'Removed from this device.'; });
  });
}

function answer(id, response) {
  run(async () => {
    await ensureLocal(id);
    await saveAnswer(id, response);
    const original = items.find(item => item.id === id);
    if (original?.shared) await share(id);
    editing = false;
    await refresh();
    channel.postMessage('changed');
    $('#status').textContent = response.skip ? 'Kept for later. No need to decide now.' : 'Your answer is saved with this item.';
    const summary = detail.querySelector('.answer-block');
    summary?.setAttribute('tabindex', '-1');
    summary?.focus();
  });
}

async function keep(capture) {
  $('#status').textContent = 'Saving…';
  const item = await capture();
  showView('library');
  await addSave(item);
  selectedId = item.id;
  editing = false;
  $('#capture-note').value = '';
  await refresh();
  channel.postMessage('changed');
  if (connection) await share(item.id);
  const hasAnswer = Boolean(items.find(saved => saved.id === item.id)?.answer);
  $('#status').textContent = hasAnswer ? 'Saved with your existing intent.' : 'Saved. Choose what it means to you.';
  const focus = detail.querySelector(hasAnswer ? '.answer-block' : '.question-title');
  focus?.setAttribute('tabindex', '-1');
  focus?.focus({preventScroll: true});
  detail.scrollIntoView({ block: 'start' });
}

async function share(id, retryUnderstanding = false) {
  $('#status').textContent = 'Local copy saved. Syncing with your library…';
  try {
    await ensureLocal(id);
    await sync(id, retryUnderstanding);
    explore.reset();
    $('#status').textContent = 'Saved to your shared library. Choose an intent below.';
  } finally {
    // Retain a newly uploaded save even if the subsequent library refresh fails.
    const local = await getSave(id);
    if (local?.shared?.remote && remoteItems && local.shared.scope === JSON.stringify([connection?.baseURL, connection?.userId])) remoteItems = [...remoteItems.filter(item => item.id !== local.shared.remoteId), local.shared.remote];
    await refresh(); channel.postMessage('changed');
  }
}

async function refreshConnection() {
  autoSync.reset();
  const revision = ++connectionRevision;
  libraryController?.abort(); clearImage(); explore.reset();
  connection = null; remoteItems = null; selectedId = undefined; editing = false;
  const saved = await getConnection();
  if (revision !== connectionRevision) return;
  await refresh();
  if (saved) {
    try {
      const inspected = await inspectConnection(saved);
      if (revision !== connectionRevision) return;
      connection = inspected;
    } catch (error) { if (revision === connectionRevision) showError(error); }
  }
  if (revision !== connectionRevision) return;
  $('#connection-label').textContent = connection ? `Library connected · ${connection.email || connection.userId}` : 'Connect a shared library';
  $('#connection-status').textContent = connection ? (connection.ai ? 'AI understanding runs on your shared backend. Your OpenAI key stays on the server.' : 'Basic suggestions. Product AI is not enabled on this server.') : 'Use your Mynah account key. It stays in this Chrome session until you disconnect or restart Chrome.';
  $('#disconnect').hidden = !connection;
  $('#shared-library').hidden = !connection;
  $('#library-refresh').hidden = !connection;
  $('#library-status').textContent = '';
  if (connection) { $('#shared-library').href = connection.baseURL; $('#backend-url').value = connection.baseURL; }
  render(); explore.render();
  if (connection) {
    await pullLibrary();
    if (view === 'explore') explore.load();
  }
}
$('#connection-form').addEventListener('submit', event => {
  event.preventDefault();
  if (busy) return;
  // Start permission request in the original user gesture.
  const pending = connect($('#backend-url').value, $('#backend-token').value);
  run(async () => { await pending; $('#backend-token').value = ''; await refreshConnection(); });
});
$('#sign-in').addEventListener('click', () => {
  const pending = startLogin($('#backend-url').value);
  run(async () => {await pending; $('#settings-dialog').close(); await refreshConnection();});
});
$('#disconnect').addEventListener('click', () => run(async () => { await disconnect(); await refreshConnection(); }));
$('#open-settings').addEventListener('click', () => { $('#connection-error').hidden = true; $('#settings-dialog').showModal(); });
$('#close-settings').addEventListener('click', () => $('#settings-dialog').close());

$('#save-page').addEventListener('click', () => run(() => keep(() => capturePage('page', $('#capture-note').value))));
$('#save-screenshot').addEventListener('click', () => run(() => keep(() => capturePage('screenshot', $('#capture-note').value))));
$('#upload').addEventListener('click', () => { uploadType = ''; $('#image-file').click(); });
$('#upload-conversation').addEventListener('click', () => { uploadType = 'conversation'; $('#image-file').click(); });
$('#image-file').addEventListener('change', event => {
  const file = event.target.files[0];
  if (file) run(() => keep(() => importImage(file, $('#capture-note').value, uploadType)));
  event.target.value = '';
});
async function syncContext() {
  if (busy) { refreshPending = true; return; }
  if (!chrome.storage?.session) { await refresh(); showError(new Error('Chrome still has the previous version loaded. Reload Mynah Finds in Chrome’s Extensions page to enable image saving.')); return; }
  const { imageCapture } = await chrome.storage.session.get('imageCapture');
  const firstRead = contextRevision === undefined;
  if (firstRead) await refresh();
  if (imageCapture && imageCapture.revision !== contextRevision) {
    contextRevision = imageCapture.revision;
    const relevant = !firstRead || items[0]?.id === imageCapture.id;
    if (imageCapture.id && relevant) { selectedId = imageCapture.id; editing = false; showView('library'); }
    $('#status').textContent = imageCapture.state === 'saving' ? 'Saving that image…' : imageCapture.id && relevant ? 'Image saved. Tap an intent below.' : '';
    $('#error').hidden = true;
    if (imageCapture.error) showError(new Error(imageCapture.error));
  }
  if (connection && imageCapture?.state === 'saved') await pullLibrary();
  else await refresh();
  if (imageCapture?.id && selectedId === imageCapture.id) detail.querySelector('.question-block')?.scrollIntoView({ block: 'start' });
}
chrome.storage?.onChanged.addListener((changes, area) => { if (area === 'session' && changes.imageCapture) syncContext().catch(showError); if (area === 'session' && changes.sharedConnection) refreshConnection().catch(showError); });
channel.onmessage = () => { if (!busy) refresh().catch(showError); else refreshPending = true; };
$('#library-tab').addEventListener('click', () => showView('library'));
$('#explore-tab').addEventListener('click', () => showView('explore'));
$('#library-query').addEventListener('input', render);
$('#library-refresh').addEventListener('click', () => run(pullLibrary));
async function refreshOnForeground() {
  if (document.hidden || !navigator.onLine || busy || editing) return;
  const latest = await getConnection().catch(error => {showError(error); return undefined;});
  if (latest === undefined) return;
  if (latest?.userId !== connection?.userId || latest?.baseURL !== connection?.baseURL || latest?.subject !== connection?.subject) {
    await refreshConnection();
  }
  if (!connection || document.querySelector('dialog[open]')) return;
  const api = client(), scope = connection.userId;
  try {
    await autoSync.check({scope, state: async () => {
      try { return await api.request('/sync'); }
      catch (error) {
        // Older servers still work while the backend PR is being rolled out.
        if (error.status === 404) return {user_id:scope, revision:Math.floor(Date.now() / 15000)};
        throw error;
      }
    }, refresh: async () => {
      await pullLibrary();
      if (view === 'explore') await explore.load();
    }});
  } catch (error) { showError(error); }
}
window.addEventListener('focus', refreshOnForeground);
window.addEventListener('online', () => {autoSync.retryAt = 0; refreshOnForeground();});
document.addEventListener('visibilitychange', () => {if (!document.hidden) refreshOnForeground();});
setInterval(refreshOnForeground, 15000);
refreshConnection().then(syncContext).catch(showError);
