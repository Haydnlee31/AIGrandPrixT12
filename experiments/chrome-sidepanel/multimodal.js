import {sharedImage} from './shared-image.js';

const scopeFor = connection => JSON.stringify([connection.baseURL, connection.userId]);
const dataAsset = value => {
  const match = /^data:(image\/(?:jpeg|png|webp)|audio\/wav);base64,([A-Za-z0-9+/=]+)$/.exec(value || '');
  if (!match) throw new Error('Use a JPEG, PNG, WebP image or a recorded WAV voice note.');
  if (match[2].length > 4 * Math.ceil(4 * 1024 * 1024 / 3)) throw new Error('An attachment is too large. Choose a smaller image or shorter recording.');
  return {media_type: match[1], data_base64: match[2]};
};

/** Every request body/key is durable before sending; retries never create another find. */
export async function syncMultimodal({id, connection, api, read, update, key = () => crypto.randomUUID(), publish = false, retryUnderstanding = false, guard = async () => {}}) {
  const scope = scopeFor(connection);
  let item = await read(id);
  if (!item) throw new Error('This local save was removed.');
  if (item.shared && item.shared.scope !== scope) throw new Error('Reconnect to the original account before syncing this find.');
  const mutate = async change => {
    await guard();
    item = await update(id, current => {
      if (current.shared && current.shared.scope !== scope) throw new Error('The account changed. Reconnect before continuing.');
      return change(current);
    });
    return item;
  };
  const setMM = change => mutate(current => ({...current, shared: {...current.shared, mm: change(current.shared.mm)}}));
  if (!item.shared) {
    const images = item.images?.length ? item.images : item.image ? [item.image] : [];
    if (images.length > 4) throw new Error('Choose at most four images for one find.');
    const assets = [];
    for (const image of images) assets.push({...dataAsset(await sharedImage(image, 3 * 1024 * 1024)), key: key(), done: false});
    if (item.audio) assets.push({...dataAsset(item.audio), key: key(), done: false});
    await mutate(current => ({...current, shared: {scope, mm: {createKey: key(), body: {
      title: item.title || '', text: item.excerpt || '', note: item.note || '',
      ...(item.url ? {url: item.url} : {}), client: 'chrome_extension'}, assets, reviewRequired: Boolean(item.audio)}}}));
  }
  if (!item.shared.mm || item.shared.remoteId) return item;
  if (item.shared.removing) throw new Error('Removal is pending. Retry Remove to finish it.');
  let mm = item.shared.mm;
  if (!mm.captureId) {
    await guard();
    const capture = await api.createMultimodalCapture(mm.body, {idempotencyKey: mm.createKey});
    await setMM(current => ({...current, captureId: capture.id, capture}));
  }
  let capture = await api.getMultimodalCapture(item.shared.mm.captureId);
  if (capture.published_save_id) {
    await mutate(current => ({...current, shared: {...current.shared, remoteId: capture.published_save_id}}));
    return item;
  }
  for (let index = 0; index < item.shared.mm.assets.length; index++) {
    let asset = item.shared.mm.assets[index];
    if (asset.done) continue;
    if (!asset.body) await setMM(current => ({...current, assets: current.assets.map((value, i) => i === index ? {...value, body: {revision: capture.revision, media_type: value.media_type, data_base64: value.data_base64}} : value)}));
    asset = item.shared.mm.assets[index];
    await guard();
    await api.uploadMultimodalAsset(capture.id, asset.body, {idempotencyKey: asset.key});
    await setMM(current => ({...current, assets: current.assets.map((value, i) => i === index ? {...value, done: true} : value)}));
    capture = await api.getMultimodalCapture(capture.id);
  }
  // Finish an uncertain correction unchanged before accepting another correction.
  if (item.shared.mm.correction && !item.shared.mm.correction.done) {
    const correction = item.shared.mm.correction;
    await guard();
    await api.updateMultimodalTranscript(capture.id, correction.assetId, correction.body, {idempotencyKey: correction.key});
    await setMM(current => ({...current, correction: {...current.correction, done: true}, analysis: null}));
    capture = await api.getMultimodalCapture(capture.id);
  }
  if (capture.stage === 'failed' && !retryUnderstanding) throw new Error('Your find is saved. Analysis needs another attempt; choose Retry analysis.');
  if (capture.stage === 'draft' || capture.stage === 'failed') {
    if (!item.shared.mm.analysis || capture.stage === 'failed') {
      await setMM(current => ({...current, analysis: {revision: capture.revision, key: key(), done: false}}));
    }
    const attempt = item.shared.mm.analysis;
    await guard();
    await api.analyzeMultimodalCapture(capture.id, attempt.revision, {idempotencyKey: attempt.key});
    await setMM(current => ({...current, analysis: {...current.analysis, done: true}}));
  }
  capture = await api.waitForMultimodalCapture(capture.id, {expectedRevision: capture.revision, timeoutMs: 180000});
  await setMM(current => ({...current, capture}));
  if (item.shared.mm.reviewRequired && !publish) return item;
  if (!item.shared.mm.publication) await setMM(current => ({...current, publication: {revision: capture.revision, key: key()}}));
  await guard();
  const publication = item.shared.mm.publication;
  const receipt = await api.publishMultimodalCapture(capture.id, publication.revision, {idempotencyKey: publication.key});
  await mutate(current => ({...current, shared: {...current.shared, remoteId: receipt.id, mm: {...current.shared.mm, capture, reviewRequired: false}}}));
  return item;
}

export async function correctTranscript({id, text, api, read, update, key = () => crypto.randomUUID(), guard = async () => {}}) {
  text = text.trim();
  if (!text || text.length > 8000) throw new Error('Enter a transcript of 1–8,000 characters.');
  const item = await read(id), mm = item?.shared?.mm;
  if (!mm?.captureId || item.shared.remoteId) throw new Error('Review the transcript before publishing this find.');
  if (mm.correction && !mm.correction.done) throw new Error('Finish the pending transcript correction by retrying analysis first.');
  await guard();
  const capture = await api.getMultimodalCapture(mm.captureId);
  const asset = capture.assets.find(asset => asset.kind === 'audio');
  if (!asset) throw new Error('No recorded voice note was found.');
  await update(id, current => ({...current, shared: {...current.shared, mm: {...current.shared.mm,
    correction: {assetId: asset.id, key: key(), body: {revision: capture.revision, transcript: text}, done: false}}}}));
}

export function searchableFind(item) {
  const analysis = item.shared?.remote?.analysis || item.shared?.mm?.capture?.result?.analysis;
  return [item.title, item.note, item.excerpt, item.answer?.label, JSON.stringify(analysis || {}),
    ...(item.shared?.mm?.capture?.assets || []).map(asset => asset.transcript || ''),
    ...(item.shared?.remote?.responses || []).map(event => event.payload?.text || event.payload?.label || '')]
    .join(' ').normalize('NFKC').toLocaleLowerCase();
}
