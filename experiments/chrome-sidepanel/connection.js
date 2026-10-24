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
  if (!capabilities.features.image_upload) throw new Error('This backend needs the image-capture update before connecting.');
  const connection = {baseURL, token: token.trim(), userId: identity.user_id, ...connectionFeatures(capabilities)};
  await chrome.storage.session.set({sharedConnection: connection});
  return connection;
}

export async function sync(id, retryUnderstanding = false) {
  return navigator.locks.request('mynah-shared-sync', async () => {
    let connection = await getConnection();
    if (!connection) throw new Error('Connect your library to share this save. Your local copy is safe.');
    if (connection.modern === undefined) connection = await inspectConnection(connection);
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
      let receipt;
      try { receipt = await api.capture(item.shared.payload, {idempotencyKey: item.shared.captureKey}); }
      catch (error) { if (error.status === 422) return; throw error; }
      item = await updateSave(id, current => ({...current, shared: {...current.shared, remoteId: receipt.id}}));
    }
    if (!item.shared.removing) item = await updateSave(id, current => ({...current, shared: {...current.shared, removing: crypto.randomUUID()}}));
    try { await api.deleteSave(item.shared.remoteId, {idempotencyKey: item.shared.removing}); }
    catch (error) { if (![404, 410].includes(error.status)) throw error; }
  });
}

export function connectionFeatures(capabilities) {
  return {ai: Boolean(capabilities.features.product_analysis || capabilities.features.multimodal_ai),
    modern: Number(capabilities.contract_version?.split('.')[1]) >= 4,
    productAnalysis: Boolean(capabilities.features.product_analysis), explore: Boolean(capabilities.features.explore),
    maxImageBytes: capabilities.capture?.max_image_bytes};
}
// Re-read capabilities for sessions connected before this extension upgrade.
export async function inspectConnection(connection) {
  const api = new CommonThreadClient(connection);
  const [identity, capabilities] = await Promise.all([api.me(), api.capabilities()]);
  if (identity.user_id !== connection.userId) throw new Error('The account changed. Reconnect in settings.');
  return {...connection, ...connectionFeatures(capabilities)};
}
