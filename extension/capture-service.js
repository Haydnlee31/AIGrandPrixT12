import {capturePayload, normalizeBackendURL, requestFingerprint, DEFAULT_BASE_URL} from './platform.js';

// Dependency injection keeps retry behavior testable without a browser.
export async function saveCapture({storage, createClient, newKey = () => crypto.randomUUID()}, input) {
  const {baseURL: configured} = await storage.local.get('baseURL');
  const baseURL = normalizeBackendURL(configured || DEFAULT_BASE_URL);
  if (input.baseURL !== baseURL) throw new Error('Backend settings changed. Reopen the capture popup before saving.');
  const token = String(input.token || '').trim();
  if (!token) throw new Error('Enter your workspace API token.');
  const payload = capturePayload(input.payload);
  const fingerprint = await requestFingerprint(baseURL, token, payload);
  const {saveAttempt: previous} = await storage.session.get('saveAttempt');
  const attempt = previous?.fingerprint === fingerprint ? previous : {fingerprint, key:newKey(), status:'pending'};
  // Commit the retry key before sending; popup closure never changes mutation identity.
  await storage.session.set({saveAttempt:attempt, auth:{baseURL, token}});
  const client = createClient({baseURL, token});
  // Replays still contact the backend: it can invalidate an old mutation after deletion.
  const result = await client.capture(payload, {idempotencyKey:attempt.key});
  await storage.session.set({saveAttempt:{...attempt, status:'saved', result}, captureDraft:null});
  return result;
}
