/** Dependency-free API transport shared by Chrome and web interfaces. */
export class APIError extends Error {
  constructor(message, {status = 0, code = 'network_error', retryable = false, requestId = null, current = null} = {}) {
    super(message);
    this.name = 'APIError';
    Object.assign(this, {status, code, retryable, requestId, current});
  }
}

export const newMutationKey = () => crypto.randomUUID();

export class CommonThreadClient {
  constructor({baseURL = 'http://127.0.0.1:8000', token, fetchImpl = globalThis.fetch} = {}) {
    const url = new URL(baseURL);
    if (url.username || url.password || url.search || url.hash || !['http:', 'https:'].includes(url.protocol) || !['', '/'].includes(url.pathname)) {
      throw new TypeError('baseURL must be an HTTP(S) origin without a path or credentials');
    }
    if (url.protocol === 'http:' && !['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)) {
      throw new TypeError('Remote API connections require HTTPS');
    }
    if (typeof fetchImpl !== 'function') throw new TypeError('A fetch implementation is required');
    this.baseURL = url.origin;
    this.token = token;
    // Window.fetch requires its native receiver in browsers; calling a stored
    // function as this.fetchImpl otherwise binds it to the SDK instance.
    this.fetchImpl = fetchImpl.bind(globalThis);
  }

  async request(path, {method = 'GET', body, idempotencyKey, signal, timeoutMs = 15000} = {}) {
    if (typeof path !== 'string' || !path.startsWith('/') || path.startsWith('//')) throw new TypeError('Use an API-relative path');
    const apiPath = path === '/health' || path.startsWith('/v1/') ? path : `/v1${path}`;
    const url = new URL(apiPath, this.baseURL);
    if (url.origin !== this.baseURL) throw new TypeError('Cross-origin API paths are not allowed');
    const mutation = !['GET', 'HEAD'].includes(method);
    if (mutation && (typeof idempotencyKey !== 'string' || !idempotencyKey.length || idempotencyKey.length > 128)) {
      throw new TypeError('Create and retain an idempotencyKey before a mutation; reuse it for an unchanged retry');
    }
    const token = typeof this.token === 'function' ? await this.token() : this.token;
    const headers = {Accept: 'application/json'};
    if (token) headers.Authorization = `Bearer ${token}`;
    if (mutation) headers['Idempotency-Key'] = idempotencyKey;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new TypeError('timeoutMs must be positive');
    const controller = new AbortController();
    const cancel = () => controller.abort(signal.reason);
    if (signal?.aborted) cancel();
    else signal?.addEventListener('abort', cancel, {once:true});
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMs);
    try {
    let response;
    try {
      response = await this.fetchImpl(url.href, {method, headers, signal:controller.signal, redirect: 'error', cache: 'no-store', ...(body === undefined ? {} : {body: JSON.stringify(body)})});
    } catch (error) {
      if (timedOut) throw new APIError('The API request timed out. Retain the original mutation key before retrying.', {code:'request_timeout', retryable:true});
      if (signal?.aborted || error.name === 'AbortError') throw error;
      throw new APIError('Could not reach the API. Retry an unchanged mutation with its original key.', {retryable:true});
    }
    const requestId = response.headers.get('X-Request-ID');
    let data;
    try { data = await response.json(); }
    catch (error) {
      if (timedOut) throw new APIError('The API request timed out. Retain the original mutation key before retrying.', {code:'request_timeout', retryable:true, requestId});
      if (signal?.aborted || error.name === 'AbortError') throw error;
      throw new APIError('The API returned an unreadable response. The result may be unknown; retain the original mutation key.', {status:response.status, code:'invalid_response', retryable:true, requestId});
    }
    if (!response.ok) {
      const e = data.error || {};
      throw new APIError(e.message || `Request failed (${response.status})`, {status:response.status, code:e.code || 'http_error', retryable:Boolean(e.retryable), requestId:e.request_id || requestId, current:e.current || null});
    }
    return data;
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', cancel);
    }
  }

  health(options) { return this.request('/health', options); }
  me(options) { return this.request('/me', options); }
  capabilities(options) { return this.request('/capabilities', options); }
  capture(payload, options) { return this.request('/saves', {...options, method:'POST', body:payload}); }
  getMedia(id, options) { return this.request(`/saves/${encodeURIComponent(id)}/media`, options); }
  retrySave(id, options) { return this.request(`/saves/${encodeURIComponent(id)}/retry`, {...options, method:'POST', body:{}}); }
  getSave(id, options) { return this.request(`/saves/${encodeURIComponent(id)}`, options); }
  collection({offset = 0, limit = 30, ...options} = {}) { return this.request(`/collection?offset=${offset}&limit=${limit}`, options); }
  respond(id, payload, options) { return this.request(`/saves/${encodeURIComponent(id)}/responses`, {...options, method:'POST', body:payload}); }
  deleteSave(id, options) { return this.request(`/saves/${encodeURIComponent(id)}`, {...options, method:'DELETE'}); }
  hypotheses(options) { return this.request('/hypotheses', options); }
  hypothesisFeedback(id, payload, options) { return this.request(`/hypotheses/${encodeURIComponent(id)}/feedback`, {...options, method:'POST', body:payload}); }
  startDiscovery(payload = {explicit:true}, options) { return this.request('/discovery-sessions', {...options, method:'POST', body:payload}); }
  discoverySessions({offset = 0, limit = 30, ...options} = {}) { return this.request(`/discovery-sessions?offset=${offset}&limit=${limit}`, options); }
  getDiscovery(id, options) { return this.request(`/discovery-sessions/${encodeURIComponent(id)}`, options); }
  discoveryEvent(id, payload, options) { return this.request(`/discovery-sessions/${encodeURIComponent(id)}/events`, {...options, method:'POST', body:payload}); }
  catalog(options) { return this.request('/catalog', options); }
  createWatch(payload, options) { return this.request('/watches', {...options, method:'POST', body:payload}); }
  watches({offset = 0, limit = 30, ...options} = {}) { return this.request(`/watches?offset=${offset}&limit=${limit}`, options); }
  getWatch(id, options) { return this.request(`/watches/${encodeURIComponent(id)}`, options); }
  updateWatch(id, payload, options) { return this.request(`/watches/${encodeURIComponent(id)}`, {...options, method:'PATCH', body:payload}); }
  simulatePrice(id, payload, options) { return this.request(`/watches/${encodeURIComponent(id)}/simulate`, {...options, method:'POST', body:payload}); }
  notifications({offset = 0, limit = 30, ...options} = {}) { return this.request(`/notifications?offset=${offset}&limit=${limit}`, options); }
  getJob(id, options) { return this.request(`/jobs/${encodeURIComponent(id)}`, options); }
  trace(options) { return this.request('/trace', options); }
  resetDemo(options) { return this.request('/demo/reset', {...options, method:'POST'}); }

  async waitForSave(id, {intervalMs = 1500, timeoutMs = 30000, signal} = {}) {
    if (!Number.isFinite(intervalMs) || !Number.isFinite(timeoutMs) || intervalMs < 100 || timeoutMs < 0) throw new TypeError('Use a finite polling interval of at least 100ms and a finite nonnegative timeout');
    const deadline = Date.now() + timeoutMs;
    while (true) {
      const item = await this.getSave(id, {signal, timeoutMs:Math.max(1, Math.min(15000, deadline - Date.now()))});
      if (item.status !== 'pending') return item;
      if (Date.now() >= deadline) throw new APIError('The item is saved but still processing. Refresh it later.', {code:'processing_timeout', retryable:true});
      await new Promise((resolve, reject) => {
        const cancel = () => { clearTimeout(timer); reject(signal.reason || new DOMException('Aborted', 'AbortError')); };
        const timer = setTimeout(() => { signal?.removeEventListener('abort', cancel); resolve(); }, Math.min(intervalMs, Math.max(0, deadline - Date.now())));
        if (signal?.aborted) cancel();
        else signal?.addEventListener('abort', cancel, {once:true});
      });
    }
  }
}
