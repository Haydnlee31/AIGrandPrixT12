// Persist every stage before sending, so a closed tab retries the same mutation.
export async function saveSharedCapture(api, attempt, persist, progress = () => {}) {
  const commit = () => persist(attempt);
  const step = suffix => ({idempotencyKey: `${attempt.key}:${suffix}`});
  if (!attempt.pipeline) {
    let capabilities;
    try { capabilities = await api.multimodalCapabilities(); }
    catch (error) { if (error.status !== 404) throw error; }
    attempt.pipeline = capabilities?.enabled ? 'multimodal' : 'legacy';
    commit();
  }
  if (attempt.pipeline === 'legacy') return api.capture(attempt.payload, {idempotencyKey: attempt.key});
  const state = attempt.multimodal ||= {};
  if (!state.id) {
    const {title, text, note, url} = attempt.payload;
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
    await api.analyzeMultimodalCapture(state.id, state.analysisRevision, step('analyze'));
    state.analyzed = true; commit();
  }
  progress('Understanding your find… You can close this tab; your save will resume when you return.');
  const capture = await api.waitForMultimodalCapture(state.id, {expectedRevision: state.revision, timeoutMs: 120000});
  if (capture.status !== 'ready') throw new Error('Analysis needs another try. Your pending save is kept on this device.');
  progress('Saving to your library…');
  return api.publishMultimodalCapture(state.id, state.revision, step('publish'));
}
