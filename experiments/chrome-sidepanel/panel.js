import { capturePage, importImage } from './capture.js';
import { addSave, listSaves, saveAnswer, deleteSave } from './storage.js';
import { safeUrl } from './questions.js';

const $ = selector => document.querySelector(selector);
const detail = $('#detail');
let items = [];
let selectedId;
let busy = false;
let editing = false;
let uploadType = '';
let contextRevision;
let refreshPending = false;
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
  $('#error').textContent = error.message || 'Something went wrong. Please try again.';
  $('#error').hidden = false;
}

async function run(work) {
  if (busy) return;
  busy = true;
  $('#error').hidden = true;
  document.querySelectorAll('button, input, textarea').forEach(control => { control.disabled = true; });
  try { await work(); }
  catch (error) { $('#status').textContent = ''; showError(error); }
  finally { busy = false; document.querySelectorAll('button, input, textarea').forEach(control => { control.disabled = false; }); if (refreshPending) { refreshPending = false; syncContext().catch(showError); } }
}

async function refresh() {
  items = await listSaves();
  if (!items.some(item => item.id === selectedId)) { selectedId = items[0]?.id; editing = false; }
  render();
}

function render() {
  $('#count').textContent = `${items.length} ${items.length === 1 ? 'save' : 'saves'}`;
  const library = $('#library');
  library.replaceChildren();
  if (!items.length) {
    const empty = element('div', 'empty');
    empty.append(element('div', 'empty-mark', '＋'), element('h3', '', 'Good ideas start somewhere.'), element('p', '', 'Save your first page or screenshot above.'));
    library.append(empty);
  }
  for (const item of items) {
    const button = element('button', 'library-item');
    button.setAttribute('aria-pressed', String(item.id === selectedId));
    const thumb = item.image ? element('img', 'thumbnail') : element('span', 'thumbnail', '↗');
    if (item.image) { thumb.src = item.image; thumb.alt = ''; }
    const copy = element('span', 'item-copy');
    const context = !item.answer ? 'Add context' : item.answer.kind === 'skipped' ? 'For later' : 'Context saved';
    copy.append(element('span', 'item-title', item.title), element('span', 'item-meta', `${labelFor(item)} · ${context}`));
    button.append(thumb, copy, element('span', 'item-arrow', '↗'));
    button.addEventListener('click', () => { selectedId = item.id; editing = false; $('#status').textContent = ''; $('#error').hidden = true; render(); detail.scrollIntoView({ block: 'start', behavior: 'smooth' }); });
    library.append(button);
  }
  renderDetail(items.find(item => item.id === selectedId));
}

function renderDetail(item) {
  detail.replaceChildren();
  detail.hidden = !item;
  if (!item) return;
  detail.append($('#detail-template').content.cloneNode(true));
  const find = selector => detail.querySelector(selector);
  find('.saved-title').textContent = item.title;
  find('.kind-badge').textContent = labelFor(item);
  if (item.image) { find('.hero-image').src = item.image; find('.hero-image').hidden = false; }
  else { find('.page-preview').hidden = false; find('.preview-domain').textContent = new URL(item.url).hostname.replace(/^www\./, ''); }
  const source = safeUrl(item.url);
  if (source) find('.source-link').href = source;
  else find('.source-link').hidden = true;
  if (item.note) { find('.saved-note').textContent = item.note; find('.saved-note').hidden = false; }
  if (item.excerpt) { find('.source-text').hidden = false; find('.source-text p').textContent = item.excerpt; }
  const showQuestion = !item.answer || editing;
  find('.question-block').hidden = !showQuestion;
  find('.answer-block').hidden = showQuestion;
  find('.question-title').textContent = item.question.prompt;
  find('.question-basis').textContent = `Suggested from ${item.question.basis}. Choose what fits, or skip.`;
  if (item.imageCapture === 'visible-crop') { find('.capture-quality').hidden = false; find('.capture-quality').textContent = 'Saved the visible part of this image. The site did not allow copying the original.'; }
  // Put the one-tap choices before the large preview, so saving never feels like a form.
  find('.saved-title').after(find('.question-block'), find('.answer-block'));
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
    if (item.answer.kind === 'skipped') find('.answer-block .eyebrow').textContent = 'SAVED FOR LATER';
    if (item.answer.kind === 'text') find('#own-answer').value = item.answer.label;
  }
  find('.edit-answer').addEventListener('click', () => { editing = true; renderDetail(item); find('.choice').focus(); });
  find('.delete').addEventListener('click', event => {
    if (event.currentTarget.dataset.confirm !== 'yes') {
      event.currentTarget.dataset.confirm = 'yes';
      event.currentTarget.textContent = 'Confirm remove';
      event.currentTarget.setAttribute('aria-label', 'Confirm remove this save');
      return;
    }
    run(async () => { await deleteSave(item.id); selectedId = undefined; editing = false; await refresh(); channel.postMessage('changed'); $('#status').textContent = 'Removed from this device.'; });
  });
}

function answer(id, response) {
  run(async () => {
    await saveAnswer(id, response);
    editing = false;
    await refresh();
    channel.postMessage('changed');
    $('#status').textContent = response.skip ? 'Kept for later. No need to decide now.' : 'Your answer is saved with this item.';
    const summary = detail.querySelector('.answer-block');
    summary.setAttribute('tabindex', '-1');
    summary.focus();
  });
}

async function keep(capture) {
  $('#status').textContent = 'Saving…';
  const item = await capture();
  await addSave(item);
  selectedId = item.id;
  editing = false;
  $('#capture-note').value = '';
  await refresh();
  channel.postMessage('changed');
  $('#status').textContent = 'Saved. Tap an intent below — no typing needed.';
  const heading = detail.querySelector('.question-title');
  heading.setAttribute('tabindex', '-1');
  heading.focus();
  detail.querySelector('.question-block').scrollIntoView({ block: 'start', behavior: 'smooth' });
}

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
  if (firstRead) items = await listSaves();
  if (imageCapture && imageCapture.revision !== contextRevision) {
    contextRevision = imageCapture.revision;
    const relevant = !firstRead || items[0]?.id === imageCapture.id;
    if (imageCapture.id && relevant) { selectedId = imageCapture.id; editing = false; }
    $('#status').textContent = imageCapture.state === 'saving' ? 'Saving that image…' : imageCapture.id && relevant ? 'Image saved. Tap an intent below.' : '';
    $('#error').hidden = true;
    if (imageCapture.error) showError(new Error(imageCapture.error));
  }
  await refresh();
  if (imageCapture?.id && selectedId === imageCapture.id) detail.querySelector('.question-block')?.scrollIntoView({ block: 'start', behavior: 'smooth' });
}
chrome.storage?.onChanged.addListener((changes, area) => { if (area === 'session' && changes.imageCapture) syncContext().catch(showError); });
channel.onmessage = () => { if (!busy) refresh().catch(showError); else refreshPending = true; };
syncContext().catch(showError);
