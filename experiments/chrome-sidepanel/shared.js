import {sharedImage} from './shared-image.js';
import {syncMultimodal} from './multimodal.js';
/** Account-bound sync. Store mutation keys before sending; retain uncertain requests. */
export function capturePayload(item, modern = false) {
  let source = item.contentType === 'product' ? 'product' : item.contentType === 'article' ? 'article' : 'web';
  try { if (/(^|\.)instagram\.com$/.test(new URL(item.url).hostname)) source = 'instagram'; } catch {}
  return {...(modern ? (item.url ? {url: item.url} : {}) : {url: item.url || ''}), title: item.title, source, client: 'chrome_extension',
    selected_text: item.excerpt || '', note: item.note || '', ...(item.image ? {[modern ? 'image_data_url' : 'image_data']: item.image} : {})};
}

export const accountScope = connection => JSON.stringify([connection.baseURL, connection.userId]);

export function sharedQuestion(remote) {
  const preview = remote.features?.multimodal_preview;
  if (preview?.schema_version === 2 && preview.prompts?.length) return {
    id: `${remote.id}:${remote.revision}`, engine: 'shared',
    prompt: 'What would you like to remember about this find?',
    basis: 'your images, notes and reviewed voice transcript',
    options: preview.prompts.map(prompt => ({id: `preview:${prompt.id}`, label: prompt.text, next: 'Your preference is saved with this find.'}))
  };
  if (!remote.suggestions?.length) return null;
  // Keep the richer local article/caption choices when the server is only running legacy demo rules.
  if (remote.features?.data_mode === 'demo_rules' && !remote.features.question) return null;
  const ai = ['openai', 'astra'].includes(remote.features?.data_mode) || Boolean(remote.analysis);
  return {id: `${remote.id}:${remote.revision}`, engine: 'shared',
    prompt: remote.features?.question || 'What caught your eye here?',
    basis: ai ? 'AI interpretation of the content you shared; check the evidence below' : 'basic suggestions; AI understanding is not enabled or could not interpret this content',
    options: remote.suggestions.map(s => ({id: s.id, label: s.text, next: s.next_step || 'Your context is saved.'}))};
}

export function answerPayload(item) {
  if (item.answer.kind === 'skipped') return {action: 'skip'};
  if (item.answer.kind === 'choice' && item.shared.remote?.suggestions?.some(s => s.id === item.answer.optionId)) {
    return {action: 'select', suggestion_id: item.answer.optionId};
  }
  return {action: 'edit', text: item.answer.label};
}

export async function syncSave({id, connection, api, read, update, retryUnderstanding = false, publish = false, guard = async () => {}, key = () => crypto.randomUUID()}) {
  const scope = accountScope(connection);
  const queued = await read(id);
  if (queued?.queuedScope && queued.queuedScope !== scope) throw new Error('This find is queued for another account. Reconnect to that account to sync.');
  const identity = await api.me();
  if (identity.user_id !== connection.userId) throw new Error('The connected account changed. Reconnect before sharing.');
  let item = await read(id);
  if (!item) throw new Error('This local save was removed.');
  if (item.shared && item.shared.scope !== scope) throw new Error('This save belongs to another shared library. Reconnect to that account to sync it.');
  if (!connection.multimodal && !item.shared && (item.audio || item.images?.length > 1 || item.kind === 'note'))
    throw new Error('This backend does not have multimodal processing enabled. Your complete find is saved locally; reconnect to the updated backend and retry.');
  const previouslyShared = Boolean(item.shared?.remoteId);
  if ((connection.multimodal && !item.shared) || (item.shared?.mm && !item.shared.remoteId)) {
    item = await syncMultimodal({id, connection, api, read, update, key, publish, retryUnderstanding, guard});
    if (!item.shared.remoteId) return item;
  }
  if (!item.shared) {
    // Resize only before the first attempt; retries retain the exact original body/key.
    const image = connection.modern && item.image ? await sharedImage(item.image, connection.maxImageBytes) : item.image;
    const payload = capturePayload({...item, image}, connection.modern);
    item = await update(id, current => ({...current, shared: {scope, captureKey: key(), payload}}));
  }
  if (item.shared.removing) throw new Error('Removal is pending. Retry Remove to finish it.');
  if (!item.shared.remoteId) {
    let receipt;
    try { receipt = await api.capture(item.shared.payload, {idempotencyKey: item.shared.captureKey}); }
    catch (error) {
      // Contract validation rejected the request before any save was created.
      if (error.status === 422) await update(id, current => { const {shared, ...local} = current; return local; });
      throw error;
    }
    item = await update(id, current => ({...current, shared: {...current.shared, remoteId: receipt.id, duplicate: receipt.duplicate}}));
  }
  if (retryUnderstanding && previouslyShared && (connection.productAnalysis || item.shared.remote?.status === 'enrichment_failed' || (connection.ai && !['openai', 'astra'].includes(item.shared.remote?.features?.data_mode)))) {
    if (!item.shared.retryKey) item = await update(id, current => ({...current, shared: {...current.shared, retryKey: key()}}));
    await api[connection.modern ? 'analyzeSave' : 'retrySave'](item.shared.remoteId, {idempotencyKey: item.shared.retryKey});
    item = await update(id, current => ({...current, shared: {...current.shared, retryKey: null}}));
  }
  const remote = await api.waitForSave(item.shared.remoteId, {timeoutMs: 120000});
  item = await update(id, current => reconcileRemote(current, remote));
  let answered = false;
  // Finish an uncertain answer before accepting a different one, using its exact body/key.
  if (item.shared.answerAttempt && !item.shared.answerAttempt.done) {
    await api.respond(remote.id, item.shared.answerAttempt.payload, {idempotencyKey: item.shared.answerAttempt.key});
    answered = true;
    item = await update(id, current => ({...current, shared: {...current.shared, answerAttempt: {...current.shared.answerAttempt, done: true}}}));
  }
  if (item.answer) {
    const payload = answerPayload(item), fingerprint = JSON.stringify(payload);
    if (item.shared.answerAttempt?.fingerprint !== fingerprint) {
      item = await update(id, current => ({...current, shared: {...current.shared, answerAttempt: {payload, fingerprint, key: key(), done: false}}}));
      await api.respond(remote.id, payload, {idempotencyKey: item.shared.answerAttempt.key});
      answered = true;
      item = await update(id, current => ({...current, shared: {...current.shared, answerAttempt: {...current.shared.answerAttempt, done: true}}}));
    }
  }
  if (answered && connection.modern) {
    const updated = await api.waitForSave(remote.id, {timeoutMs: 120000});
    item = await update(id, current => reconcileRemote(current, updated));
  }
  return item;
}

/** Pull server edits only when no local answer is waiting to be sent. */
export function reconcileRemote(current, remote) {
  if (current.shared?.remoteId && current.shared.remoteId !== remote.id) throw new Error('The AI response belongs to a different find. Refresh this save to try again.');
  if (current.shared?.remote?.revision > remote.revision) return current;
  const pending = current.answer && (!current.shared.answerAttempt?.done || current.shared.answerAttempt.fingerprint !== JSON.stringify(answerPayload(current)));
  const latest = [...(remote.responses || [])].reverse().find(event => event.event_type === 'annotation_response');
  const updated = {...current, title: remote.title || current.title, question: sharedQuestion(remote) || current.question,
    shared: {...current.shared, remote, syncedAt: new Date().toISOString()}};
  if (latest && !pending) {
    const response = latest.payload, suggestion = remote.suggestions?.find(s => s.id === response.suggestion_id);
    updated.answer = {kind: response.action === 'skip' ? 'skipped' : suggestion && response.action === 'select' ? 'choice' : 'text',
      optionId: suggestion?.id, label: response.action === 'skip' ? 'Kept for later' : response.label || response.text || suggestion?.text || 'Context saved',
      next: response.next_step || '', questionId: updated.question.id, answeredAt: new Date(latest.occurred_at * 1000).toISOString()};
    updated.shared.answerAttempt = {done: true, fingerprint: JSON.stringify(answerPayload(updated))};
  }
  return updated;
}
