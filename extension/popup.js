import {DEFAULT_BASE_URL, normalizeBackendURL, validatePageURL, capturePayload} from './platform.js';

const form = document.querySelector('#capture');
const status = document.querySelector('#status');
const fields = document.querySelector('#capture-fields');
const saveButton = document.querySelector('#save');
const newCaptureButton = document.querySelector('#new-capture');
let baseURL = DEFAULT_BASE_URL;
let activeURL;
let saving = false;
let attemptedDraftRevision;

function report(message, kind = '') {
  status.textContent = message;
  status.dataset.kind = kind;
}
function formData() { return Object.fromEntries(new FormData(form)); }
async function stateRequest(message) {
  const response = await chrome.runtime.sendMessage(message);
  if (!response?.ok) throw new Error(response?.error?.message || 'This draft could not be kept. Reopen the popup and retry.');
  return response.result;
}
function storeDraft(data = formData()) {
  const {token, ...draft} = data;
  return stateRequest({type:'capture:draft', baseURL, payload:draft});
}
document.querySelector('#settings').addEventListener('click', () => chrome.runtime.openOptionsPage());

async function initialize() {
  try {
    const [settings, session] = await Promise.all([
      chrome.storage.local.get('baseURL'), chrome.storage.session.get(['auth', 'captureDraft'])
    ]);
    baseURL = normalizeBackendURL(settings.baseURL || DEFAULT_BASE_URL);
    document.querySelector('#backend').textContent = baseURL;
    document.querySelector('#library').href = baseURL;
    form.elements.token.value = session.auth?.baseURL === baseURL ? session.auth.token : (baseURL === DEFAULT_BASE_URL ? 'demo-alex' : '');
    const [tab] = await chrome.tabs.query({active:true, currentWindow:true});
    activeURL = validatePageURL(tab?.url);
    let captured = {url:activeURL, title:(tab.title || new URL(activeURL).hostname).slice(0,300), selected_text:'', note:''};
    let partial = false;
    try {
      const [script] = await chrome.scripting.executeScript({
        target:{tabId:tab.id},
        func:() => ({url:location.href, title:document.title.slice(0,300), selected_text:window.getSelection()?.toString().slice(0,12000) || ''})
      });
      if (script?.result) {
        activeURL = validatePageURL(script.result.url);
        captured = {...captured, ...script.result, url:activeURL};
      }
      else partial = true;
    } catch { partial = true; }
    if (session.captureDraft?.url === activeURL && session.captureDraft?.baseURL === baseURL) {
      captured = {...captured, ...session.captureDraft};
    }
    for (const name of ['url', 'title', 'selected_text', 'note']) form.elements[name].value = captured[name] || '';
    fields.disabled = false;
    document.querySelector('#workspace-access').open = !form.elements.token.value;
    report(partial ? 'Chrome blocked reading selected text here. The page link and title are still available; review them before saving.' : 'Ready to save. Only the content shown above will be sent.');
  } catch (error) {
    report(error.message, 'error');
  }
}

form.addEventListener('input', () => {
  if (!saving && activeURL) storeDraft().catch(() => report('This draft could not be kept. Retry after reopening the popup.', 'error'));
});
form.elements.token.addEventListener('invalid', () => { document.querySelector('#workspace-access').open = true; });
form.addEventListener('submit', async event => {
  event.preventDefault();
  if (saving) return;
  saving = true;
  saveButton.disabled = true;
  newCaptureButton.hidden = true;
  try {
    const input = formData();
    const payload = capturePayload(input);
    fields.disabled = true;
    const {revision} = await storeDraft(input);
    attemptedDraftRevision = revision;
    report('Saving to your Library…');
    const response = await chrome.runtime.sendMessage({type:'capture:save', baseURL, token:input.token, payload, draftRevision:revision});
    if (!response?.ok) {
      const error = new Error(response?.error?.message || 'The save request did not respond. Retry without changing your details.');
      error.code = response?.error?.code;
      throw error;
    }
    report(response.result.duplicate ? 'This link is already in your Library.' : 'Saved to your Library.', 'success');
    saveButton.textContent = 'Save to Library';
  } catch (error) {
    report(error.message, 'error');
    saveButton.textContent = 'Retry save';
    newCaptureButton.hidden = error.code !== 'mutation_expired';
  } finally {
    saving = false;
    fields.disabled = false;
    saveButton.disabled = false;
  }
});

// A deletion-invalidated request requires an explicit new intent, never an automatic retry key.
newCaptureButton.addEventListener('click', async () => {
  try {
    await stateRequest({type:'capture:reset', baseURL, draftRevision:attemptedDraftRevision});
    newCaptureButton.hidden = true;
    report('New save started. Review the content, then choose Save to Library.');
    saveButton.textContent = 'Save to Library';
  } catch (error) { report(error.message, 'error'); }
});
initialize();
