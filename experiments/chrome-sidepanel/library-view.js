import {questionFor} from './questions.js';
import {accountScope, reconcileRemote} from './shared.js';

export function remoteSave(remote, connection) {
  const item = {id: `shared:${accountScope(connection)}:${remote.id}`, title: remote.title,
    url: remote.original_url, excerpt: remote.selected_text || '', note: remote.note || '',
    kind: remote.has_image ? 'image' : 'page', image: null,
    createdAt: new Date(remote.captured_at * 1000).toISOString(), answer: null,
    shared: {scope: accountScope(connection), remoteId: remote.id}, remoteOnly: true};
  item.question = questionFor(item);
  return reconcileRemote(item, remote);
}

/** Never expose another account's cache or resurrect a remotely removed find. */
export function mergeLibrary(local, remote, connection) {
  const scope = connection && accountScope(connection);
  const remaining = new Map((remote || []).map(item => [item.id, item]));
  const items = [];
  for (const item of local) {
    if (!item.shared) { items.push(item); continue; }
    if (item.shared.scope !== scope) continue;
    const record = remaining.get(item.shared.remoteId);
    if (record) {
      items.push(reconcileRemote(item, record));
      remaining.delete(record.id);
    } else if (!item.shared.remoteId || remote === null) items.push(item);
  }
  if (connection) for (const record of remaining.values()) items.push(remoteSave(record, connection));
  return items.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
}

export function catalogImage(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.hostname === 'amazon-berkeley-objects.s3.us-east-1.amazonaws.com' && !url.username && !url.password ? url.href : null;
  } catch { return null; }
}
