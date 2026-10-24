/** Account-bound sync. Store mutation keys before sending; retain uncertain requests. */
export function capturePayload(item) {
  let source = item.contentType === 'article' ? 'article' : 'web';
  try { if (/(^|\.)instagram\.com$/.test(new URL(item.url).hostname)) source = 'instagram'; } catch {}
  return {url: item.url || '', title: item.title, source, client: 'chrome_extension',
    selected_text: item.excerpt || '', note: item.note || '', ...(item.image ? {image_data: item.image} : {})};
}

export const accountScope = connection => JSON.stringify([connection.baseURL, connection.userId]);

export function sharedQuestion(remote) {
  if (!remote.suggestions?.length) return null;
  // Keep the richer local article/caption choices when the server is only running legacy demo rules.
  if (remote.features?.data_mode === 'demo_rules' && !remote.features.question) return null;
  const ai = remote.features?.data_mode === 'openai';
  return {id: `${remote.id}:${remote.revision}`, engine: 'shared',
    prompt: remote.features?.question || 'What caught your eye here?',
    basis: ai ? 'AI interpretation of the content you shared; check the evidence below' : 'basic suggestions; AI understanding is not enabled or could not interpret this content',
    options: remote.suggestions.map(s => ({id: s.id, label: s.text, next: s.next_step || 'Your context is saved.'}))};
}

export function answerPayload(item) {
  if (item.answer.kind === 'skipped') return {action: 'skip'};
  if (item.answer.kind === 'choice' && item.shared.remote?.suggestions.some(s => s.id === item.answer.optionId)) {
    return {action: 'select', suggestion_id: item.answer.optionId};
  }
  return {action: 'edit', text: item.answer.label};
}

export async function syncSave({id, connection, api, read, update, retryUnderstanding = false, key = () => crypto.randomUUID()}) {
  const scope = accountScope(connection);
  const identity = await api.me();
  if (identity.user_id !== connection.userId) throw new Error('The connected account changed. Reconnect before sharing.');
  let item = await read(id);
  if (!item) throw new Error('This local save was removed.');
  if (item.shared && item.shared.scope !== scope) throw new Error('This save belongs to another shared library. Reconnect to that account to sync it.');
  if (!item.shared) item = await update(id, current => ({...current, shared: {scope, captureKey: key(), payload: capturePayload(current)}}));
  if (item.shared.removing) throw new Error('Removal is pending. Retry Remove to finish it.');
  if (!item.shared.remoteId) {
    const receipt = await api.capture(item.shared.payload, {idempotencyKey: item.shared.captureKey});
    item = await update(id, current => ({...current, shared: {...current.shared, remoteId: receipt.id, duplicate: receipt.duplicate}}));
  }
  if (retryUnderstanding && (item.shared.remote?.status === 'enrichment_failed' || (connection.ai && item.shared.remote?.features?.data_mode !== 'openai'))) {
    if (!item.shared.retryKey) item = await update(id, current => ({...current, shared: {...current.shared, retryKey: key()}}));
    await api.retrySave(item.shared.remoteId, {idempotencyKey: item.shared.retryKey});
    item = await update(id, current => ({...current, shared: {...current.shared, retryKey: null}}));
  }
  const remote = await api.waitForSave(item.shared.remoteId, {timeoutMs: 25000});
  item = await update(id, current => {
    const pendingAnswer = current.answer && (!current.shared.answerAttempt?.done || current.shared.answerAttempt.fingerprint !== JSON.stringify(answerPayload(current)));
    const latest = [...(remote.responses || [])].reverse().find(event => event.event_type === 'annotation_response');
    const updated = {...current, question: sharedQuestion(remote) || current.question, shared: {...current.shared, remote, syncedAt: new Date().toISOString()}};
    if (latest && !pendingAnswer) {
      const response = latest.payload, suggestion = remote.suggestions.find(s => s.id === response.suggestion_id);
      updated.answer = {kind: response.action === 'skip' ? 'skipped' : suggestion && response.action === 'select' ? 'choice' : 'text',
        optionId: suggestion?.id, label: response.action === 'skip' ? 'Kept for later' : response.label || response.text || suggestion?.text || 'Context saved',
        next: response.next_step || '', questionId: updated.question.id, answeredAt: new Date(latest.occurred_at * 1000).toISOString()};
      updated.shared.answerAttempt = {done: true, fingerprint: JSON.stringify(answerPayload(updated))};
    }
    return updated;
  });
  // Finish an uncertain answer before accepting a different one, using its exact body/key.
  if (item.shared.answerAttempt && !item.shared.answerAttempt.done) {
    await api.respond(remote.id, item.shared.answerAttempt.payload, {idempotencyKey: item.shared.answerAttempt.key});
    item = await update(id, current => ({...current, shared: {...current.shared, answerAttempt: {...current.shared.answerAttempt, done: true}}}));
  }
  if (item.answer) {
    const payload = answerPayload(item), fingerprint = JSON.stringify(payload);
    if (item.shared.answerAttempt?.fingerprint !== fingerprint) {
      item = await update(id, current => ({...current, shared: {...current.shared, answerAttempt: {payload, fingerprint, key: key(), done: false}}}));
      await api.respond(remote.id, payload, {idempotencyKey: item.shared.answerAttempt.key});
      item = await update(id, current => ({...current, shared: {...current.shared, answerAttempt: {...current.shared.answerAttempt, done: true}}}));
    }
  }
  return item;
}
