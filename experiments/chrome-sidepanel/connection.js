import { CommonThreadClient } from './lib/client.js';
import { normalizeBackendURL } from './lib/platform.js';
import { getSave, updateSave, listSaves } from './storage.js';
import { syncSave, accountScope, needsSync } from './shared.js';
import {sessionRequest, sessionToken} from './login.js';

export async function getConnection({allowCached = false} = {}) {
  const {managedLogin} = await chrome.storage.local.get('managedLogin');
  if (!managedLogin) return (await chrome.storage.session.get('sharedConnection')).sharedConnection || null;
  const {baseURL} = managedLogin;
  const current = async () => (await chrome.storage.local.get('managedLogin')).managedLogin?.generation === managedLogin.generation;
  const hydrate = metadata => ({...metadata, token:sessionToken({baseURL, subject:metadata.subject, stillConnected:current})});
  try {
    const session = await sessionRequest(baseURL, 'get-session?disableCookieCache=true');
    if (!await current()) return null;
    if (!session?.user) return allowCached && managedLogin.verified ? hydrate(managedLogin.verified) : null;
    const subject = session.user.id;
    if (managedLogin.verified?.subject === subject) return hydrate(managedLogin.verified);
    const token = sessionToken({baseURL, subject, stillConnected:current});
    const api = new CommonThreadClient({baseURL, token});
    const [identity, capabilities] = await Promise.all([api.me(), api.capabilities()]);
    if (!await current()) return null;
    const verified = {baseURL, userId:identity.user_id, subject, email:session.user.email, managed:true, ...connectionFeatures(capabilities)};
    await chrome.storage.local.set({managedLogin:{...managedLogin, verified}});
    return hydrate(verified);
  } catch (error) {
    // Cached identity permits queuing only. Each upload still requires a fresh,
    // account-checked token, so an offline save cannot switch users later.
    if (allowCached && managedLogin.verified && await current()) return hydrate(managedLogin.verified);
    throw error;
  }
}
export async function disconnect() {
  await chrome.storage.local.remove('managedLogin');
  await chrome.storage.session.remove('sharedConnection');
}

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
  await chrome.storage.local.remove('managedLogin');
  await chrome.storage.session.set({sharedConnection: connection});
  return connection;
}

export async function sync(id, retryUnderstanding = false) {
  return navigator.locks.request('mynah-shared-sync', async () => {
    let connection = await getConnection({allowCached:true});
    if (!connection) throw new Error('Connect your library to share this save. Your local copy is safe.');
    if (connection.modern === undefined) connection = await inspectConnection(connection);
    return syncSave({id, connection, retryUnderstanding, api: new CommonThreadClient({baseURL: connection.baseURL, token: connection.token}), read: getSave, update: updateSave});
  });
}

export async function retryPending(connection) {
  const scope = accountScope(connection);
  for (const item of await listSaves()) {
    const shared = item.shared;
    if (!shared || shared.scope !== scope || shared.removing || shared.paused || shared.retryAt > Date.now()) continue;
    if (!needsSync(item)) continue;
    try { await sync(item.id); }
    catch (error) {
      const paused = [400,404,409,410,413,422].includes(error.status);
      await updateSave(item.id, current => current.shared ? ({...current, shared:{...current.shared, paused, retryAt:Date.now()+60000}}) : current);
    }
  }
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
