import {PagedFeed} from './lib/feed.js';
import {EXPLORE_EMPTY, exploreKey, priceText, currentOffer, offerLink, sourceLink} from './lib/presentation.js';
import {safeLink} from './lib/library.js';
import {catalogImage} from './library-view.js';

export function element(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined) el.textContent = text;
  return el;
}
function link(label, href) {
  const el = element('a', 'text-button', `${label} ↗`);
  el.href = href; el.target = '_blank'; el.rel = 'noopener noreferrer';
  return el;
}
function productImage(product) {
  const url = catalogImage(product.offer?.image_url);
  if (!url) return element('div', 'product-placeholder', product.category || 'Catalog find');
  const img = element('img', 'product-image');
  img.src = url; img.alt = ''; img.loading = 'lazy'; img.referrerPolicy = 'no-referrer';
  img.addEventListener('error', () => img.replaceWith(element('div', 'product-placeholder', product.category || 'Catalog find')), {once: true});
  return img;
}

export function renderInsights(target, remote, explore) {
  const analysis = remote?.analysis || remote?.features?.analysis;
  target.replaceChildren();
  if (!remote) return;
  target.append(element('h3', '', 'Based on your find'));
  target.append(element('p', '', analysis?.summary || remote.features?.summary || (remote.status === 'pending' ? 'Taking a closer look… Refresh this find in a moment.' : remote.status === 'enrichment_failed' ? 'Your find is saved. Try “Refresh AI insights” below to finish understanding it.' : 'Add context or refresh AI insights to understand the products in this find.')));
  for (const product of analysis?.products || []) {
    const section = element('section', 'product-insight');
    section.append(element('h4', '', product.product_type));
    if (product.category_path?.length) section.append(element('p', 'field-help', product.category_path.join(' › ')));
    const facts = element('ul', 'facts');
    for (const [name, fact] of [['Brand', product.brand], ['Model', product.model], ...(product.attributes || []).map(fact => [fact.name, fact])]) {
      if (!fact) continue;
      const row = element('li');
      row.append(element('strong', '', `${name}: `), document.createTextNode(fact.value), element('span', 'fact-basis', `${fact.certainty === 'inferred' ? 'Suggested' : 'Observed'} · ${fact.basis.replaceAll('_', ' ')}`));
      const evidence = element('details'); evidence.append(element('summary', '', 'Evidence'), element('p', '', fact.evidence)); row.append(evidence); facts.append(row);
    }
    section.append(facts);
    const button = element('button', 'text-button accent', 'Explore related products ↗');
    button.addEventListener('click', () => explore(product.product_type.slice(0, 100)));
    section.append(button); target.append(section);
  }
  if (analysis?.uncertainties?.length) {
    const details = element('details'); details.append(element('summary', '', 'A few things to check'));
    const list = element('ul'); for (const text of analysis.uncertainties) list.append(element('li', '', text));
    details.append(list); target.append(details);
  }
  if (analysis) target.append(element('p', 'field-help', 'AI observations from your saved content. Check details against the original.'));
}

export function createExplore({client, connection, openFind, openSettings}) {
  const $ = selector => document.querySelector(selector);
  const feed = new PagedFeed({key: exploreKey, onChange: render});
  let query = '';
  const dialog = $('#product-dialog');
  $('#close-product').addEventListener('click', () => dialog.close());
  $('#explore-form').addEventListener('submit', event => {event.preventDefault(); search($('#explore-query').value.trim());});
  $('#explore-refresh').addEventListener('click', () => load());
  $('#explore-more').addEventListener('click', () => load(true));
  function search(value = '') { query = value; $('#explore-query').value = value; return load(); }
  function reset() { feed.clear(); dialog.close(); $('#product-body').replaceChildren(); query = ''; $('#explore-query').value = ''; render(); }
  function load(append = false) {
    if (!connection()?.explore) { render(); return; }
    const api = client();
    return feed.load(options => api.explore({query, limit: 12, ...options}), {append});
  }
  function render() {
    const container = $('#explore-results'); container.replaceChildren();
    const connected = connection();
    $('#explore-form').hidden = !connected?.explore;
    $('#explore-refresh').hidden = !connected?.explore;
    $('#explore-more').hidden = feed.page?.next_offset == null;
    $('#explore-more').disabled = feed.loading;
    $('#explore-more').textContent = feed.loading ? 'Loading…' : 'More ideas';
    $('#explore-status').textContent = feed.loading ? 'Finding possibilities…' : feed.page ? (feed.page.mode === 'personalized' ? `Ideas from ${feed.page.personalized_from_saves} shared ${feed.page.personalized_from_saves === 1 ? 'find' : 'finds'}` : `Catalog results for “${feed.page.query}”`) : '';
    if (!connected?.explore) {
      const empty = element('div', 'empty');
      empty.append(element('h3', '', connected ? 'Explore needs the shared backend.' : 'Ideas start with your finds.'), element('p', '', connected ? 'Connect to mynah-finds.vercel.app to use the same catalog as the web app.' : 'Connect your shared library to see AI shopping insights and recommendations across your devices.'));
      const button = element('button', 'text-button accent', 'Connect shared library'); button.addEventListener('click', openSettings); empty.append(button); container.append(empty); return;
    }
    if (feed.error) {
      container.append(element('p', 'error', feed.error.message));
      const retry = element('button', 'text-button accent', 'Try again'); retry.addEventListener('click', () => load(Boolean(feed.items.length))); container.append(retry);
    }
    if (!feed.items.length && !feed.loading && !feed.error) {
      const [title, description] = EXPLORE_EMPTY[feed.page?.status] || EXPLORE_EMPTY.ready;
      const empty = element('div', 'empty'); empty.append(element('h3', '', title), element('p', '', description)); container.append(empty);
    }
    const grid = element('div', 'product-grid');
    for (const item of feed.items) {
      const card = element('button', 'product-card');
      card.append(productImage(item.product), element('h3', '', item.product.title));
      if (item.reasons[0]) card.append(element('p', 'product-reason', item.reasons[0].text));
      const offer = item.product.offer;
      card.append(element('p', 'product-price', priceText(offer.price_minor, offer.currency)), element('span', 'field-help', currentOffer(item) ? 'Current catalog offer' : 'Catalog record · price & stock unverified'), element('span', 'why-link', 'Why this? ↗'));
      card.addEventListener('click', () => showProduct(item)); grid.append(card);
    }
    container.append(grid);
  }
  function showProduct(item) {
    const body = $('#product-body'); body.replaceChildren();
    const p = item.product, citation = item.catalog_citation;
    $('#product-title').textContent = 'Recommended find';
    body.append(productImage(p), element('h2', '', p.title));
    if (p.description) body.append(element('p', '', p.description));
    body.append(element('h3', '', 'Why this?'));
    for (const reason of item.reasons) {
      const section = element('section', 'reason-block'); section.append(element('p', '', reason.text));
      if (reason.catalog_field) section.append(element('p', 'field-help', `${reason.catalog_field.replaceAll('_', ' ')}: ${reason.catalog_value || ''}`));
      if (reason.saved_item_id) {
        const button = element('button', 'text-button accent', `From: ${reason.saved_item_title || 'your saved find'}`);
        button.addEventListener('click', () => {dialog.close(); openFind(reason.saved_item_id);}); section.append(button);
      }
      body.append(section);
    }
    body.append(element('h3', '', 'From the catalog'), element('p', '', `${currentOffer(item) ? 'Price' : 'Recorded price'}: ${priceText(p.offer.price_minor, p.offer.currency)}`), element('p', '', currentOffer(item) ? 'Confirm availability and delivery with the seller.' : 'This catalog record is not a verified current offer. Check price and availability with the seller.'));
    const url = offerLink(item) || sourceLink(item); if (url) body.append(link(offerLink(item) ? 'View offer' : 'View source record', url));
    body.append(element('h3', '', 'Source'), element('p', '', citation.attribution || citation.title || p.source_id));
    if (citation.license_id) body.append(element('p', 'field-help', citation.license_id));
    const license = safeLink(citation.license_url); if (license) body.append(link('Source license', license));
    dialog.showModal(); dialog.scrollTop = 0;
  }
  return {load, search, reset, render};
}
