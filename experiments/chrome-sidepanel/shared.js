import {activeIntents, questionFor} from './questions.js';

/** Account-bound sync. Store mutation keys before sending; retain uncertain requests. */
export function capturePayload(item, connection = {}) {
  let source = item.contentType === 'article' ? 'article' : 'web';
  try { if (/(^|\.)instagram\.com$/.test(new URL(item.url).hostname)) source = 'instagram'; } catch {}
  const modern = connection.imageField === 'image_data_url';
  return {...(item.url || !modern ? {url: item.url || ''} : {}), title: item.title, source, client: 'chrome_extension',
    selected_text: item.excerpt || '', note: item.note || '', ...(item.image ? {[modern ? 'image_data_url' : 'image_data']: item.image} : {})};
}

export const accountScope = connection => JSON.stringify([connection.baseURL, connection.userId]);

export function sharedQuestion(remote) {
  if (!remote.suggestions?.length) return null;
  // Keep the richer local article/caption choices when the server is only running legacy demo rules.
  if (remote.features?.data_mode === 'demo_rules') return null;
  const ai = ['openai', 'astra'].includes(remote.features?.data_mode);
  return {id: `${remote.id}:${remote.revision}`, engine: 'shared', phase: remote.suggestions.every(s => s.kind === 'intent') ? 'action' : 'why',
    prompt: remote.features?.question || (remote.features?.subject ? `What would you like to do with ${remote.features.subject}?` : 'What caught your eye here?'),
    basis: ai ? 'AI interpretation of the content you shared; check the evidence below' : 'basic suggestions; AI understanding is not enabled or could not interpret this content',
    options: remote.suggestions.map(s => ({id: s.id, label: s.text, next: s.next_step || 'Your context is saved.'}))};
}

export function answerPayload(item) {
  if (item.answer.kind === 'removed') return {action: 'reject', retract_event_id: item.answer.retractEventId};
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
  if (!item.shared) item = await update(id, current => ({...current, shared: {scope, captureKey: key(), payload: capturePayload(current, connection)}}));
  if (item.shared.removing) throw new Error('Removal is pending. Retry Remove to finish it.');
  if (!item.shared.remoteId) {
    const receipt = await api.capture(item.shared.payload, {idempotencyKey: item.shared.captureKey});
    item = await update(id, current => ({...current, shared: {...current.shared, remoteId: receipt.id, duplicate: receipt.duplicate}}));
  }
  if (retryUnderstanding && (item.shared.remote?.status === 'enrichment_failed' || (connection.ai && item.shared.remote?.features?.data_mode !== (connection.annotationMode || 'openai')))) {
    if (!item.shared.retryKey) item = await update(id, current => ({...current, shared: {...current.shared, retryKey: key()}}));
    await api.retrySave(item.shared.remoteId, {idempotencyKey: item.shared.retryKey});
    item = await update(id, current => ({...current, shared: {...current.shared, retryKey: null}}));
  }
  let remote = await api.waitForSave(item.shared.remoteId, {timeoutMs: 25000});
  item = await update(id, current => ({...current, shared: {...current.shared, remote}}));
  let sent = false;
  // Finish an uncertain answer unchanged before sending any newer local choices.
  if (item.shared.answerAttempt && !item.shared.answerAttempt.done) {
    const attempt = item.shared.answerAttempt;
    await api.respond(remote.id, attempt.payload, {idempotencyKey: attempt.key});
    sent = true;
    item = await update(id, current => ({...current,
      ...(current.pendingAnswers ? {pendingAnswers: current.pendingAnswers.filter(answer => attempt.answerId ? answer.id !== attempt.answerId : JSON.stringify(answerPayload({...current, answer})) !== attempt.fingerprint)} : {}),
      shared: {...current.shared, answerAttempt: {...attempt, done: true}}}));
  }
  // Older installations have one answer and no queue. Upgrade it in place.
  if (!item.pendingAnswers) {
    const pending = item.answer && item.shared.answerAttempt?.fingerprint !== JSON.stringify(answerPayload(item));
    item = await update(id, current => ({...current, pendingAnswers: pending ? [current.answer] : []}));
  }
  while (item.pendingAnswers.length) {
    const answer = item.pendingAnswers[0];
    const payload = answerPayload({...item, answer}), fingerprint = JSON.stringify(payload);
    const attempt = {payload, fingerprint, key: key(), answerId: answer.id, done: false};
    item = await update(id, current => ({...current, shared: {...current.shared, answerAttempt: attempt}}));
    await api.respond(remote.id, payload, {idempotencyKey: attempt.key});
    sent = true;
    item = await update(id, current => ({...current, pendingAnswers: current.pendingAnswers.slice(1), shared: {...current.shared, answerAttempt: {...attempt, done: true}}}));
  }
  if (sent) remote = await api.waitForSave(remote.id, {timeoutMs: 25000});
  return update(id, current => {
    const responses = (remote.responses || []).filter(event => event.event_type === 'annotation_response');
    const hasActiveFlags = responses.some(event => typeof event.active === 'boolean');
    const active = hasActiveFlags ? responses.filter(event => event.active) : responses.slice(-1).filter(event => ['select', 'edit'].includes(event.payload.action));
    const intents = active.map(event => {
      const response = event.payload, suggestion = remote.suggestions.find(s => s.id === response.suggestion_id);
      return {id: event.id, eventId: event.id, kind: response.action === 'select' ? 'choice' : 'text',
        optionId: response.suggestion_id, label: response.label || response.text || suggestion?.text || 'Context saved',
        phase: (response.kind || suggestion?.kind) === 'intent' ? 'action' : 'why', next: response.next_step || '',
        answeredAt: new Date(event.occurred_at * 1000).toISOString()};
    });
    // Older servers/mocks may omit response history. Never discard local answers on that basis.
    const resolved = hasActiveFlags || responses.length ? intents : activeIntents(current);
    const candidate = sharedQuestion(remote);
    const whyKnown = Boolean(current.note?.trim()) || resolved.some(intent => (intent.phase || 'why') === 'why');
    const question = candidate?.phase === 'action' && !whyKnown ? questionFor(current) : candidate || current.question;
    const latest = responses.at(-1);
    const answer = resolved.at(-1) || (latest?.payload.action === 'skip' ? {kind: 'skipped', label: 'Kept for later', next: 'No purchase or monitoring has started.'} : hasActiveFlags && latest?.payload.action === 'reject' ? {kind: 'removed', label: 'No active intents', next: 'You can add context whenever you like.'} : current.answer);
    return {...current, question, intents: resolved, answer,
      shared: {...current.shared, remote, syncedAt: new Date().toISOString()}};
  });
}
