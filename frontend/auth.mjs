import {sessionToken} from './session-token.mjs';
// Neon manages the persistent, HTTP-only session cookie. No password or library
// key is kept in application storage; the API receives short-lived signed JWTs.
export async function loadLogin(onChange) {
  const response = await fetch('/v1/auth/config', {cache:'no-store'});
  if (!response.ok) throw new Error('Could not load sign-in. Please refresh.');
  const config = await response.json();
  if (!config.enabled) return null;
  const url = new URL(config.auth_url);
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) throw new Error('Invalid sign-in configuration.');
  // Use Neon's HTTP contract through our same-origin transport. A fresh session
  // lookup also sees sign-outs/account changes from another tab immediately.
  async function request(operation, body) {
    const result = await fetch('/v1/auth/session/' + operation, {
      method:body === undefined ? 'GET' : 'POST', credentials:'include', cache:'no-store', redirect:'error',
      signal:AbortSignal.timeout(20000), headers:{'X-Mynah-Auth':'1', ...(body === undefined ? {} : {'Content-Type':'application/json'})},
      ...(body === undefined ? {} : {body:JSON.stringify(body)}),
    });
    const data = await result.json();
    if (!result.ok) throw new Error(data.message || 'Could not sign in. Please try again.');
    return {data};
  }
  const auth = {
    getSession: () => request('get-session?disableCookieCache=true'),
    token: () => request('token'), signOut: () => request('sign-out', {}),
    emailOtp: {sendVerificationOtp: body => request('email-otp/send-verification-otp', body)},
    signIn: {emailOtp: body => request('sign-in/email-otp', body)},
  };
  let user = null, generation = 0, flight = null;
  const unwrap = result => {
    if (result.error) throw new Error(result.error.message || 'Sign-in could not finish. Please try again.');
    return result.data;
  };
  async function refresh() {
    if (flight) return flight;
    const started = generation;
    const pending = (async () => {
      const result = unwrap(await auth.getSession({query: {disableCookieCache: true}}));
      if (started !== generation) return user;
      const next = result?.user || null;
      if (next?.id !== user?.id) {
        user = next;
        const current = ++generation, userId = next?.id;
        onChange({user, token: next ? sessionToken({
          subject:userId, isCurrent:() => generation === current,
          session:async () => unwrap(await auth.getSession()),
          issueToken:async () => unwrap(await auth.token()), onExpired:refresh,
        }) : null});
      }
      return user;
    })();
    flight = pending;
    try { return await pending; } finally { if (flight === pending) flight = null; }
  }
  const dialog = document.createElement('dialog');
  dialog.id = 'login-dialog'; dialog.setAttribute('aria-labelledby', 'login-title');
  dialog.innerHTML = `<form id="login-form"><div class="sheet-handle" aria-hidden="true"></div><div class="dialog-heading"><h2 id="login-title">Sign in to Mymah Finds</h2><button class="icon-button" type="button" data-close aria-label="Close">×</button></div><p>One library for your iPhone, web and Chrome. We’ll email you a sign-in code.</p><label for="login-email">Email address</label><input id="login-email" type="email" autocomplete="email" required><div id="login-code-fields" hidden><label for="login-code">Code from your email</label><input id="login-code" inputmode="numeric" autocomplete="one-time-code" maxlength="12"></div><p id="login-status" role="status"></p><div class="sheet-footer"><button class="primary wide" type="submit">Email me a code</button></div><button id="login-start-over" class="text-button" type="button" hidden>Use another email</button></form>`;
  document.body.appendChild(dialog);
  const form = dialog.querySelector('form'), email = dialog.querySelector('#login-email'), code = dialog.querySelector('#login-code'), fields = dialog.querySelector('#login-code-fields'), status = dialog.querySelector('#login-status'), submit = form.querySelector('[type=submit]'), restart = dialog.querySelector('#login-start-over');
  let sent = false, busy = false;
  const reset = () => {sent = false; code.value = ''; code.required = false; fields.hidden = true; email.readOnly = false; restart.hidden = true; submit.textContent = 'Email me a code'; status.textContent = '';};
  restart.addEventListener('click', reset);
  form.addEventListener('submit', async event => {
    event.preventDefault(); event.stopPropagation();
    if (busy) return;
    busy = true; submit.disabled = true; restart.disabled = true; status.textContent = '';
    try {
      if (!sent) {
        unwrap(await auth.emailOtp.sendVerificationOtp({email:email.value.trim(), type:'sign-in'}));
        sent = true; fields.hidden = false; code.required = true; email.readOnly = true; restart.hidden = false; submit.textContent = 'Sign in'; status.textContent = 'Check your inbox for a sign-in code.'; code.focus();
      } else {
        unwrap(await auth.signIn.emailOtp({email:email.value.trim(), otp:code.value.trim()}));
        code.value = '';
        generation++; flight = null; user = null;
        await refresh();
        if (!user) throw new Error('Your browser could not keep the login session. Check cookie settings and try again.');
        dialog.close(); reset();
      }
    } catch (error) {status.textContent = error.message;}
    finally {busy = false; submit.disabled = false; restart.disabled = false;}
  });
  // Keep the sign-in UI and foreground retry available during a provider outage.
  try { await refresh(); } catch (error) { status.textContent = error.message; }
  return {
    signIn: () => {reset(); dialog.showModal(); email.focus();},
    profile: () => {reset(); dialog.showModal(); email.value = user?.email || ''; email.focus();},
    signOut: async () => {unwrap(await auth.signOut()); user = null; generation++; onChange({token:null, user:null});},
    refresh,
    get user() {return user;},
  };
}
