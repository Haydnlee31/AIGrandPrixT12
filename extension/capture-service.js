import {capturePayload, normalizeBackendURL, requestFingerprint, DEFAULT_BASE_URL} from './platform.js';
import {withCaptureState} from './capture-state.js';

// Dependency injection keeps retry behavior testable without a browser.
export async function saveCapture({storage, createClient, newKey = () => crypto.randomUUID(), newRunId = () => crypto.randomUUID()}, input) {
  const token = String(input.token || '').trim();
  if (!token) throw new Error('Enter your workspace API token.');
  const payload = capturePayload(input.payload);
  const {baseURL, attempt, draftSnapshot} = await withCaptureState(storage, async () => {
    const {baseURL: configured} = await storage.local.get('baseURL');
    const baseURL = normalizeBackendURL(configured || DEFAULT_BASE_URL);
    if (input.baseURL !== baseURL) throw new Error('Backend settings changed. Reopen the capture popup before saving.');
    const session = await storage.session.get(['saveAttempt', 'captureDraft']);
    if (input.draftRevision !== undefined && session.captureDraft?.revision !== input.draftRevision) {
      throw new Error('This draft changed before saving. Reopen the popup and review the current draft.');
    }
    const fingerprint = await requestFingerprint(baseURL, token, payload);
    const previous = session.saveAttempt;
    const attempt = {...(previous?.fingerprint === fingerprint ? previous : {fingerprint, key:newKey(), status:'pending'}), runId:newRunId()};
    // The retry key identifies the mutation; runId owns only this completion.
    // A newer retry can reuse the key without letting the older request publish.
    await storage.session.set({saveAttempt:attempt, auth:{baseURL, token}});
    return {baseURL, attempt, draftSnapshot:JSON.stringify(session.captureDraft ?? null)};
  });
  const client = createClient({baseURL, token});
  // Replays still contact the backend: it can invalidate an old mutation after deletion.
  const result = await client.capture(payload, {idempotencyKey:attempt.key});
  await withCaptureState(storage, async () => {
    const settings = await storage.local.get('baseURL');
    const session = await storage.session.get(['saveAttempt', 'captureDraft', 'auth']);
    if (normalizeBackendURL(settings.baseURL || DEFAULT_BASE_URL) !== baseURL ||
        session.auth?.baseURL !== baseURL || session.auth?.token !== token ||
        session.saveAttempt?.key !== attempt.key || session.saveAttempt?.runId !== attempt.runId ||
        session.saveAttempt?.fingerprint !== attempt.fingerprint ||
        JSON.stringify(session.captureDraft ?? null) !== draftSnapshot) return;
    await storage.session.set({saveAttempt:{...attempt, status:'saved', result}, captureDraft:null});
  });
  return result;
}
