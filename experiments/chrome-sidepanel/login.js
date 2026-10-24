import {normalizeBackendURL} from './lib/platform.js';

// Chrome sends the web app's HttpOnly session cookie only to the host the user
// has granted. Credentials never enter extension storage or content scripts.
export async function sessionRequest(baseURL, operation, fetchImpl = fetch) {
  const response = await fetchImpl(`${normalizeBackendURL(baseURL)}/v1/auth/session/${operation}`, {
    headers:{'X-Mynah-Auth':'1'}, credentials:'include', cache:'no-store', redirect:'error',
    signal:AbortSignal.timeout(15000),
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.message || 'Could not check your sign-in. Please try again.');
  return data;
}

export function sessionToken({baseURL, subject, stillConnected, request = sessionRequest}) {
  return async () => {
    if (!await stillConnected()) throw new Error('Your library connection changed.');
    const session = await request(baseURL, 'get-session?disableCookieCache=true');
    if (session?.user?.id !== subject) throw new Error('Your sign-in changed. Reopen Mynah to switch libraries safely.');
    const result = await request(baseURL, 'token');
    if (!await stillConnected() || !result?.token) throw new Error('Please sign in again to sync.');
    // Guard an account switch between get-session and token. Authentication is
    // still performed by the backend's signature/issuer/audience checks.
    let tokenSubject;
    try { tokenSubject = JSON.parse(atob(result.token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).sub; } catch {}
    if (tokenSubject !== subject) throw new Error('Your sign-in changed. Reconnect before syncing.');
    return result.token;
  };
}

export async function startLogin(input) {
  const baseURL = normalizeBackendURL(input), url = new URL(baseURL);
  const granted = await chrome.permissions.request({origins:[`${url.protocol}//${url.hostname}/*`]});
  if (!granted) throw new Error('Allow access to your Mynah server to sign in.');
  await chrome.storage.local.set({managedLogin:{baseURL}});
  await chrome.storage.session.remove('sharedConnection');
  await chrome.tabs.create({url:`${baseURL}/?sign-in=1#profile`});
}
