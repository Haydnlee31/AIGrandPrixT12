/** Render only server-returned evidence and persisted intent; never invent commerce facts. */
export async function showUnderstanding(root, item, {api, scope, isCurrent, onSaved}) {
  const el = (tag, text, className) => { const node = document.createElement(tag); if (text) node.textContent = text; if (className) node.className = className; return node; };
  const active = () => root.isConnected && isCurrent();
  root.replaceChildren();
  const status = el('p', '', 'subtitle'); status.setAttribute('role', 'status');
  const features = item.features || {};
  const ai = ['openai', 'astra'].includes(features.data_mode);
  root.append(el('h3', ai ? 'Understand this find' : 'Give this find context'));
  if (features.summary) root.append(el('p', features.summary));
  root.append(el('p', ai ? 'AI interpretation. Source claims and image readings may be wrong; check the original.' : 'Basic suggestions. This save has not received a live AI interpretation.', 'subtitle'));
  for (const evidence of features.evidence || []) root.append(el('blockquote', `${evidence.text} — ${evidence.source === 'image' ? 'AI reading of image (unverified)' : 'Quote from saved content (not independently verified)'}`));
  const activeIntents = item.responses.filter(event => event.event_type === 'annotation_response' && event.active);
  if (activeIntents.length) {
    root.append(el('h4', 'Your saved intents'));
    for (const intent of activeIntents) {
      const label = intent.payload.label || intent.payload.text || item.suggestions.find(s => s.id === intent.payload.suggestion_id)?.text || 'Context saved';
      root.append(el('p', label));
      if (intent.payload.next_step) root.append(el('p', intent.payload.next_step));
      const remove = el('button', 'Remove this intent', 'text-button');
      remove.onclick = () => mutate('respond', {action: 'reject', retract_event_id: intent.id});
      root.append(remove);
    }
  }
  async function mutate(operation, payload) {
    if (!active()) return;
    const storageKey = JSON.stringify(['mynah-context', scope, item.id]);
    let attempt;
    try { attempt = JSON.parse(sessionStorage.getItem(storageKey)); } catch {}
    const fingerprint = JSON.stringify([operation, payload]);
    if (attempt && attempt.fingerprint !== fingerprint) {
      status.textContent = 'An earlier answer is waiting to be confirmed. Retry that same choice before changing it.'; return;
    }
    if (!attempt) { attempt = {key: crypto.randomUUID(), fingerprint}; sessionStorage.setItem(storageKey, JSON.stringify(attempt)); }
    root.querySelectorAll('button').forEach(button => button.disabled = true);
    try {
      status.textContent = 'Saving…';
      if (operation === 'retry') await api.retrySave(item.id, {idempotencyKey: attempt.key});
      else await api.respond(item.id, payload, {idempotencyKey: attempt.key});
      sessionStorage.removeItem(storageKey);
      const updated = await api.waitForSave(item.id);
      if (active()) { onSaved(updated); showUnderstanding(root, updated, {api, scope, isCurrent, onSaved}); }
    } catch (error) {
      if (active()) {
        status.textContent = error.message || 'Could not confirm this answer. Retry the same choice.';
        if ([404, 410, 422].includes(error.status)) sessionStorage.removeItem(storageKey);
      }
    } finally { if (active()) root.querySelectorAll('button').forEach(button => button.disabled = false); }
  }
  if (item.status === 'ready') {
    root.append(el('h4', features.question || (features.subject ? `What would you like to do with ${features.subject}?` : 'What caught your eye here?')));
    for (const suggestion of item.suggestions) {
      const button = el('button', suggestion.text, 'secondary wide intent-choice');
      const selected = activeIntents.some(intent => intent.payload.suggestion_id === suggestion.id);
      button.setAttribute('aria-pressed', String(selected));
      if (selected) button.textContent = `✓ ${suggestion.text}`;
      button.onclick = () => { if (!selected) mutate('respond', {action: 'select', suggestion_id: suggestion.id}); };
      root.append(button);
    }
    const skip = el('button', 'Not now', 'text-button'); skip.onclick = () => mutate('respond', {action: 'skip'}); root.append(skip);
  } else {
    status.textContent = item.status === 'pending' ? 'Saved. Understanding is still processing.' : 'Saved. Understanding failed; your original content is safe.';
    const retry = el('button', item.status === 'pending' ? 'Check for question' : 'Retry understanding', 'secondary');
    retry.onclick = async () => {
      if (item.status === 'enrichment_failed') return mutate('retry', {});
      retry.disabled = true;
      try { const updated = await api.waitForSave(item.id); if (active()) { onSaved(updated); showUnderstanding(root, updated, {api, scope, isCurrent, onSaved}); } }
      catch (error) { if (active()) status.textContent = error.message; }
      finally { retry.disabled = false; }
    };
    root.append(retry);
  }
  root.append(status);
  if (item.has_image) {
    try {
      const media = await api.getMedia(item.id);
      if (active() && /^data:image\/(png|jpeg|webp);base64,/.test(media.image_data)) {
        const image = el('img', '', 'saved-media'); image.src = media.image_data; image.alt = 'Original saved image'; root.prepend(image);
      }
    } catch { if (active()) root.append(el('p', 'The saved image could not load. Reopen this find to retry.')); }
  }
}
