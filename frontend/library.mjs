/** Library-only view model. No inference or commerce calls belong in this layer. */
export const SOURCE_NAMES = {web:'Web links',article:'Articles',product:'Product links',pinterest:'Pinterest',instagram:'Instagram'};
export function sourceHost(item) {
  try { return new URL(item.original_url).hostname.replace(/^www\./,''); }
  catch { return 'Saved link'; }
}
export function safeLink(value) {
  try { const url = new URL(value); return ['https:','http:'].includes(url.protocol) && !url.username && !url.password ? url.href : null; }
  catch { return null; }
}
export function visibleSaves(items, {query='',source='all',sort='newest'}={}) {
  const terms = query.normalize('NFKC').toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);
  return items.filter(item => {
    if (source !== 'all' && item.source !== source) return false;
    const text = [item.title,item.note,item.selected_text,item.source,SOURCE_NAMES[item.source],item.original_url].filter(Boolean).join(' ').normalize('NFKC').toLocaleLowerCase();
    return terms.every(term=>text.includes(term));
  }).sort((a,b)=>sort==='title' ? a.title.localeCompare(b.title) : sort==='oldest' ? a.captured_at-b.captured_at : b.captured_at-a.captured_at);
}
export async function loadSavedLibrary(client, options={}) {
  const items = new Map(), offsets = new Set();
  let offset=0;
  do {
    if (offsets.has(offset)) throw new Error('Your library could not finish loading. Please refresh.');
    offsets.add(offset);
    const page = await client.collection({offset,limit:100,...options});
    for (const item of page.items) items.set(item.id,item);
    offset=page.next_offset;
  } while (offset != null);
  return [...items.values()];
}
