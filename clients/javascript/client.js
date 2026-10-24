/** Dependency-free API transport shared by Chrome and web interfaces. */
export class APIError extends Error {
  constructor(message, {status = 0, code = 'network_error', retryable = false, requestId = null, current = null} = {}) {
    super(message);
    this.name = 'APIError';
    Object.assign(this, {status, code, retryable, requestId, current});
  }
}

export const newMutationKey = () => crypto.randomUUID();

const validCatalogSource = source => typeof source === 'string' && /^[a-z][a-z0-9_]{0,63}(?![\s\S])/.test(source);
const validCatalogItemId = id => typeof id === 'string' && id.length > 0 && [...id].length <= 1024 && !['.', '..'].includes(id) && !/[\\/\u0000-\u001f]/.test(id);

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
  getSave(id, options) { return this.request(`/saves/${encodeURIComponent(id)}`, options); }
  collection({offset = 0, limit = 30, ...options} = {}) { return this.request(`/collection?offset=${offset}&limit=${limit}`, options); }
  searchLibrary({query = '', category, limit = 20, offset = 0, ...options} = {}) {
    if (typeof query !== 'string' || [...query].length > 200 || /[\u0000-\u001f\u007f]/.test(query) ||
        (category !== undefined && (typeof category !== 'string' || !category.trim() || [...category].length > 80 || /[\u0000-\u001f\u007f]/.test(category)))) throw new TypeError('Use a Library query up to 200 characters and a category up to 80 characters without control characters');
    if (!Number.isInteger(limit) || limit < 1 || limit > 100 || !Number.isInteger(offset) || offset < 0 || offset > 100000) throw new TypeError('Use a Library limit of 1–100 and offset of 0–100000');
    const params = new URLSearchParams({q:query, limit:String(limit), offset:String(offset)});
    if (category !== undefined) params.set('category', category);
    return this.request(`/library/search?${params}`, options);
  }
  analyzeSave(id, options) {
    if (typeof id !== 'string' || !id.length || [...id].length > 200 || ['.', '..'].includes(id) || /[\\/\u0000-\u001f\u007f]/.test(id)) throw new TypeError('Use a single saved-item ID returned by the Library');
    return this.request(`/saves/${encodeURIComponent(id)}/analyze`, {...options, method:'POST'});
  }
  respond(id, payload, options) { return this.request(`/saves/${encodeURIComponent(id)}/responses`, {...options, method:'POST', body:payload}); }
  deleteSave(id, options) { return this.request(`/saves/${encodeURIComponent(id)}`, {...options, method:'DELETE'}); }
  hypotheses(options) { return this.request('/hypotheses', options); }
  hypothesisFeedback(id, payload, options) { return this.request(`/hypotheses/${encodeURIComponent(id)}/feedback`, {...options, method:'POST', body:payload}); }
  startDiscovery(payload = {explicit:true}, options) { return this.request('/discovery-sessions', {...options, method:'POST', body:payload}); }
  discoverySessions({offset = 0, limit = 30, ...options} = {}) { return this.request(`/discovery-sessions?offset=${offset}&limit=${limit}`, options); }
  getDiscovery(id, options) { return this.request(`/discovery-sessions/${encodeURIComponent(id)}`, options); }
  discoveryEvent(id, payload, options) { return this.request(`/discovery-sessions/${encodeURIComponent(id)}/events`, {...options, method:'POST', body:payload}); }
  catalog(options) { return this.request('/catalog', options); }
  catalogSources(options) { return this.request('/commerce/sources', options); }
  explore({query = '', source, limit = 20, offset = 0, ...options} = {}) {
    if (source !== undefined && !validCatalogSource(source)) throw new TypeError('Use a catalog source name returned by the backend');
    if (typeof query !== 'string' || [...query].length > 100 || /[\u0000-\u001f\u007f]/.test(query) ||
        !Number.isInteger(limit) || limit < 1 || limit > 50 || !Number.isInteger(offset) || offset < 0 || offset >= 500) throw new TypeError('Use an Explore query up to 100 characters, limit of 1–50, and offset below 500');
    const params = new URLSearchParams({q:query, limit:String(limit), offset:String(offset)});
    if (source !== undefined) params.set('source', source);
    return this.request(`/explore?${params}`, options);
  }
  searchProducts({source, query, limit = 20, offset = 0, deliveryCountry, ...options} = {}) {
    if (!validCatalogSource(source) || typeof query !== 'string' || !query.trim() || [...query].length > 100 || /[\u0000-\u001f]/.test(query)) throw new TypeError('Choose a catalog source and provide a search query of 1–100 characters without control characters');
    if (!Number.isInteger(limit) || limit < 1 || limit > 50 || !Number.isInteger(offset) || offset < 0 || offset >= 1000000) throw new TypeError('Use a catalog limit of 1–50 and an offset below 1000000');
    if (deliveryCountry !== undefined) throw new TypeError('Catalog data does not establish delivery eligibility');
    const params = new URLSearchParams({source, q:query, limit:String(limit), offset:String(offset)});
    return this.request(`/commerce/search?${params}`, options);
  }
  catalogItem(source, id, options) {
    if (!validCatalogSource(source) || !validCatalogItemId(id)) throw new TypeError('Use a catalog source and a single bounded record ID returned by product search');
    return this.request(`/commerce/items/${encodeURIComponent(source)}/${encodeURIComponent(id)}`, options);
  }
  createWatch(payload, options) { return this.request('/watches', {...options, method:'POST', body:payload}); }
  createCatalogWatch(payload, options) { return this.request('/watches/catalog', {...options, method:'POST', body:payload}); }
  priceHistory(id, {offset = 0, limit = 30, ...options} = {}) { return this.request(`/watches/${encodeURIComponent(id)}/history?offset=${offset}&limit=${limit}`, options); }
  checkWatch(id, options) { return this.request(`/watches/${encodeURIComponent(id)}/check`, {...options, method:'POST'}); }
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
