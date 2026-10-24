import { CommonThreadClient } from './lib/client.js';
import { normalizeBackendURL } from './lib/platform.js';
import { getSave, updateSave } from './storage.js';
import { syncSave, accountScope } from './shared.js';

export const getConnection = async () => (await chrome.storage.session.get('sharedConnection')).sharedConnection || null;
export const disconnect = () => chrome.storage.session.remove('sharedConnection');

export async function connect(baseURL, token) {
  baseURL = normalizeBackendURL(baseURL);
  if (!token.trim()) throw new Error('Enter the backend access token. This is not your OpenAI API key.');
  const url = new URL(baseURL);
  // Chrome host permissions cover all ports on the chosen hostname.
  const granted = await chrome.permissions.request({origins: [`${url.protocol}//${url.hostname}/*`]});
  if (!granted) throw new Error('Access to this backend was not granted. Local saving still works.');
  const api = new CommonThreadClient({baseURL, token: token.trim()});
  const [identity, capabilities] = await Promise.all([api.me(), api.capabilities()]);
  if (!capabilities.features.image_upload || !capabilities.features.multiple_intents) throw new Error('Update the shared backend to support images and multiple intents before connecting. Your local saves are safe.');
  const connection = {baseURL, token: token.trim(), userId: identity.user_id, ai: Boolean(capabilities.features.multimodal_ai || capabilities.features.predictive_prompts),
    annotationMode: capabilities.data_modes.annotations, multipleIntents: capabilities.features.multiple_intents === true,
    imageField: capabilities.features.image_data_url ? 'image_data_url' : 'image_data'};
  await chrome.storage.session.set({sharedConnection: connection});
  return connection;
}

export async function sync(id, retryUnderstanding = false) {
  return navigator.locks.request('mynah-shared-sync', async () => {
    const connection = await getConnection();
    if (!connection) throw new Error('Connect your library to share this save. Your local copy is safe.');
    if (!connection.multipleIntents) throw new Error('Reconnect your library to check support for multiple intents. Your local saves are safe.');
    return syncSave({id, connection, retryUnderstanding, api: new CommonThreadClient({baseURL: connection.baseURL, token: connection.token}), read: getSave, update: updateSave});
  });
}

export async function removeShared(id) {
  return navigator.locks.request('mynah-shared-sync', async () => {
    let item = await getSave(id);
    if (!item?.shared) return;
    const connection = await getConnection();
    if (!connection || item.shared.scope !== accountScope(connection)) throw new Error('Reconnect to this save’s shared account to remove both copies.');
    const api = new CommonThreadClient({baseURL: connection.baseURL, token: connection.token});
    const identity = await api.me();
    if (identity.user_id !== connection.userId) throw new Error('Reconnect to the original account first.');
    // A capture with an unknown result must be recovered before deleting its server copy.
    if (!item.shared.remoteId) {
      const receipt = await api.capture(item.shared.payload, {idempotencyKey: item.shared.captureKey});
      item = await updateSave(id, current => ({...current, shared: {...current.shared, remoteId: receipt.id}}));
    }
    if (!item.shared.removing) item = await updateSave(id, current => ({...current, shared: {...current.shared, removing: crypto.randomUUID()}}));
    try { await api.deleteSave(item.shared.remoteId, {idempotencyKey: item.shared.removing}); }
    catch (error) { if (![404, 410].includes(error.status)) throw error; }
  });
}
