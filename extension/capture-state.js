import {normalizeBackendURL, DEFAULT_BASE_URL} from './platform.js';

// All popup/options state writes run in the service worker through this queue.
// Chrome storage has no compare-and-swap operation: checking a revision and
// writing outside this queue would still allow a newer draft to be overwritten.
// Hold the queue only for short storage operations, never for network requests.
const queues = new WeakMap();
export function withCaptureState(storage, operation) {
  const pending = (queues.get(storage) || Promise.resolve()).then(operation);
  queues.set(storage, pending.catch(() => {}));
  return pending;
}

export async function writeCaptureDraft(storage, input, newRevision = () => crypto.randomUUID()) {
  return withCaptureState(storage, async () => {
    const settings = await storage.local.get('baseURL');
    const baseURL = normalizeBackendURL(settings.baseURL || DEFAULT_BASE_URL);
    if (input.baseURL !== baseURL) throw new Error('Backend settings changed. Reopen the capture popup before saving.');
    // Keep incomplete edits (for example a half-typed URL) recoverable. Full
    // capture validation belongs to Save, not to draft persistence.
    const payload = {};
    for (const [name, limit] of Object.entries({url:2048, title:300, selected_text:12000, note:2000})) {
      const value = input.payload?.[name] ?? '';
      if (typeof value !== 'string' || value.length > limit) throw new Error('This draft exceeds the supported field lengths.');
      payload[name] = value;
    }
    const revision = newRevision();
    await storage.session.set({captureDraft:{
      url:payload.url, title:payload.title, selected_text:payload.selected_text,
      note:payload.note, baseURL, revision
    }});
    return {revision};
  });
}

export async function resetCaptureAttempt(storage, input = {}) {
  return withCaptureState(storage, async () => {
    const settings = await storage.local.get('baseURL');
    const baseURL = normalizeBackendURL(settings.baseURL || DEFAULT_BASE_URL);
    const session = await storage.session.get('captureDraft');
    if ((input.baseURL !== undefined && input.baseURL !== baseURL) ||
        (input.draftRevision !== undefined && input.draftRevision !== session.captureDraft?.revision)) {
      throw new Error('This draft or connection changed. Reopen the popup before starting a new save.');
    }
    await storage.session.remove('saveAttempt');
  });
}

export async function changeCaptureBackend(storage, requestedURL) {
  return withCaptureState(storage, async () => {
    const baseURL = normalizeBackendURL(requestedURL);
    const settings = await storage.local.get('baseURL');
    const oldBaseURL = normalizeBackendURL(settings.baseURL || DEFAULT_BASE_URL);
    if (baseURL !== oldBaseURL) {
      await storage.session.remove(['auth', 'captureDraft', 'saveAttempt']);
    }
    await storage.local.set({baseURL});
    return {baseURL, oldBaseURL};
  });
}
