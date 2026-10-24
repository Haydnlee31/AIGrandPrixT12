// Persist every stage before sending, so a closed tab retries the same mutation.
export async function saveSharedCapture(api, attempt, persist, progress = () => {}, {retryFailed = false, isCurrent = () => true, signal} = {}) {
  const check = () => {
    if (signal?.aborted || !isCurrent()) throw new DOMException('This save is paused because your account changed.', 'AbortError');
  };
  const commit = () => { check(); return persist(attempt); };
  const step = suffix => ({idempotencyKey: `${attempt.key}:${suffix}`, ...(signal ? {signal} : {})});
  check();
  if (!attempt.pipeline) {
    let capabilities;
    try { capabilities = await api.multimodalCapabilities({signal}); }
    catch (error) { if (error.status !== 404) throw error; }
    attempt.pipeline = capabilities?.enabled ? 'multimodal' : 'legacy';
    commit();
  }
  check();
  if (attempt.pipeline === 'legacy') return api.capture(attempt.payload, {idempotencyKey: attempt.key, signal});
  const state = attempt.multimodal ||= {};
  if (state.failed) {
    if (!retryFailed) throw Object.assign(new Error('Review your pending find and retry analysis.'), {status:422});
    state.analyzed = false; state.failed = false;
    state.analysisKey = crypto.randomUUID(); attempt.paused = false; commit();
  }
  if (!state.id) {
    const {title, note, url} = attempt.payload;
    const text = attempt.payload.selected_text ?? attempt.payload.text;
    const capture = await api.createMultimodalCapture({title, text, note, url, client: 'web'}, step('create'));
    state.id = capture.id; state.revision = capture.revision; commit();
  }
  if (attempt.payload.image_data_url && !state.uploaded) {
    const [, media_type, data_base64] = attempt.payload.image_data_url.match(/^data:(image\/(?:jpeg|png|webp));base64,(.+)$/) || [];
    if (!media_type) throw new Error('Choose a JPEG, PNG or WebP image.');
    state.uploadRevision ??= state.revision; commit();
    const capture = await api.uploadMultimodalAsset(state.id,
      {revision: state.uploadRevision, media_type, data_base64}, step('image'));
    state.revision = capture.revision; state.uploaded = true; commit();
  }
  if (!state.analyzed) {
    state.analysisRevision ??= state.revision; commit();
    await api.analyzeMultimodalCapture(state.id, state.analysisRevision,
      state.analysisKey ? {idempotencyKey:state.analysisKey, signal} : step('analyze'));
    state.analyzed = true; commit();
  }
  progress('Understanding your find… You can close this tab; your save will resume when you return.');
  let capture;
  try {
    capture = await api.waitForMultimodalCapture(state.id, {expectedRevision: state.revision, timeoutMs: 120000, signal});
  } catch (error) {
    check();
    let current;
    try { current = await api.getMultimodalCapture?.(state.id, {signal}); } catch {}
    check();
    if (current?.status === 'enrichment_failed') {
      state.failed = true; attempt.paused = true; commit(); error.status = 422;
    }
    throw error;
  }
  check();
  if (capture.status !== 'ready') throw new Error('Analysis needs another try. Your pending save is kept on this device.');
  progress('Saving to your library…');
  return api.publishMultimodalCapture(state.id, state.revision, step('publish'));
}

export function contextualPrompts(item) {
  const preview = item?.features?.multimodal_preview;
  if (preview?.schema_version !== 2 || !Array.isArray(preview.prompts) || preview.prompts.length !== 3) return [];
  return preview.prompts.every((prompt, index) => prompt?.id === `p${index + 1}` &&
      typeof prompt.text === 'string' && prompt.text.trim() && prompt.text.length <= 2000 &&
      typeof prompt.question === 'string' && prompt.question.trim() && prompt.question.length <= 2000)
    ? preview.prompts.map(({id, text, question}) => ({id, text, question})) : [];
}
