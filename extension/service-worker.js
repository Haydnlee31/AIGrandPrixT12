import {CommonThreadClient} from './lib/client.js';
import {saveCapture} from './capture-service.js';
import {changeCaptureBackend, resetCaptureAttempt, writeCaptureDraft} from './capture-state.js';
import {backendPermission, DEFAULT_BASE_URL, normalizeBackendURL, readableError} from './platform.js';

const popupURL = chrome.runtime.getURL('popup.html');
const optionsURL = chrome.runtime.getURL('options.html');
let captureQueue = Promise.resolve();

async function protectStorage() {
  await chrome.storage.local.setAccessLevel({accessLevel:'TRUSTED_CONTEXTS'});
  await chrome.storage.session.setAccessLevel({accessLevel:'TRUSTED_CONTEXTS'});
}
chrome.runtime.onInstalled.addListener(() => { protectStorage().catch(() => {}); });
chrome.runtime.onStartup.addListener(() => { protectStorage().catch(() => {}); });

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // No content-script sender, arbitrary fetch URL, or external message is accepted.
  if (sender.id !== chrome.runtime.id) return false;
  const popupMessage = sender.url === popupURL && ['capture:save', 'capture:draft', 'capture:reset'].includes(message?.type);
  const optionsMessage = sender.url === optionsURL && message?.type === 'capture:backend';
  if (!popupMessage && !optionsMessage) return false;
  const respond = promise => {
    promise.then(result => sendResponse({ok:true, result})).catch(error => sendResponse({ok:false, error:{message:readableError(error), code:error.code || 'capture_failed', retryable:Boolean(error.retryable), requestId:error.requestId || null}}));
  };
  if (message.type === 'capture:draft') {
    respond(writeCaptureDraft(chrome.storage, message));
    return true;
  }
  if (message.type === 'capture:reset') {
    respond(resetCaptureAttempt(chrome.storage, message));
    return true;
  }
  if (message.type === 'capture:backend') {
    respond((async () => {
      const baseURL = normalizeBackendURL(message.baseURL);
      if (!await chrome.permissions.contains({origins:[backendPermission(baseURL)]})) {
        throw new Error('Backend permission is missing. Allow this backend before saving settings.');
      }
      return changeCaptureBackend(chrome.storage, baseURL);
    })());
    return true;
  }
  // A reopened popup can overlap a request already running in this worker.
  // Serialize mutations so both attempts observe the same persisted retry key.
  captureQueue = captureQueue.catch(() => {}).then(async () => {
    const settings = await chrome.storage.local.get('baseURL');
    const baseURL = normalizeBackendURL(settings.baseURL || DEFAULT_BASE_URL);
    if (!await chrome.permissions.contains({origins:[backendPermission(baseURL)]})) {
      throw new Error('Backend permission is missing. Open Settings and allow this backend before saving.');
    }
    return saveCapture({storage:chrome.storage, createClient:settings => new CommonThreadClient(settings)}, message);
  });
  respond(captureQueue);
  return true;
});
