import {DEFAULT_BASE_URL, normalizeBackendURL, backendPermission} from './platform.js';

const form = document.querySelector('#settings-form');
const field = document.querySelector('#base-url');
const status = document.querySelector('#status');
const connect = document.querySelector('#connect');
let previous = DEFAULT_BASE_URL;
function report(message, kind = '') { status.textContent = message; status.dataset.kind = kind; }

chrome.storage.local.get('baseURL').then(settings => {
  previous = normalizeBackendURL(settings.baseURL || DEFAULT_BASE_URL);
  field.value = previous;
  report('Open Mymah Finds from the toolbar to review a page and save it to your Library.');
}).catch(error => report(error.message, 'error'));

document.querySelector('#local').addEventListener('click', () => { field.value = DEFAULT_BASE_URL; field.focus(); });
form.addEventListener('submit', async event => {
  event.preventDefault();
  let baseURL;
  try {
    baseURL = normalizeBackendURL(field.value);
    // Keep request inside this user gesture, before any await or storage read.
    const permission = chrome.permissions.request({origins:[backendPermission(baseURL)]});
    connect.disabled = true;
    if (!await permission) throw new Error('Access was not allowed. Your previous backend is still selected.');
    const response = await chrome.runtime.sendMessage({type:'capture:backend', baseURL});
    if (!response?.ok) throw new Error(response?.error?.message || 'Backend settings could not be saved.');
    const {oldBaseURL} = response.result;
    previous = baseURL;
    field.value = baseURL;
    // Release the old optional origin after committing settings; local default is required.
    if (oldBaseURL !== baseURL && oldBaseURL !== DEFAULT_BASE_URL) {
      try { await chrome.permissions.remove({origins:[backendPermission(oldBaseURL)]}); }
      catch { /* Settings remain usable if Chrome already removed the old grant. */ }
    }
    report('Library connected. Reopen Mymah Finds and enter this workspace’s token.', 'success');
  } catch (error) {
    report(error.message || 'Settings could not be saved.', 'error');
  } finally { connect.disabled = false; }
});
