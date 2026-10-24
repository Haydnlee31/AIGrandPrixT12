import {CommonThreadClient, newMutationKey} from './lib/client.js?v=3';
import {showUnderstanding} from './understanding.js';
import {SOURCE_NAMES, sourceHost, safeLink, visibleSaves, loadSavedLibrary} from './library.mjs';

const $ = (selector,root=document) => root.querySelector(selector);
const escape = (value='') => String(value).replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
const store = {get(key) { try { return sessionStorage.getItem(key); } catch { return null; } },set(key,value) { try { sessionStorage.setItem(key,value); } catch {} },remove(key) { try { sessionStorage.removeItem(key); } catch {} }};
let token = store.get('mymah-finds-token') ?? store.get('common-thread-token') ?? 'demo-alex';
let view = ['library','search','profile'].includes(location.hash.slice(1)) ? location.hash.slice(1) : 'library';
let items=[], account=null, query='', source='all', sort='newest', layout=store.get('mymah-finds-layout') || 'grid';
let loading=true, loadError='', toastTimer, connectionRevision=0, accountIntent=0, refreshPromise, refreshController, captureAttempt=null, captureFlight=null, removeAttempt=null;
const removalAttempts=new Map();
const client = () => new CommonThreadClient({baseURL:location.origin,token});
const paths = {plus:'<path d="M12 5v14M5 12h14"/>',search:'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',arrow:'<path d="M5 12h14m-6-6 6 6-6 6"/>',chevron:'<path d="m9 5 7 7-7 7"/>',link:'<path d="m10 13 4-4M9 15l-2 2a3.5 3.5 0 0 1-5-5l4-4a3.5 3.5 0 0 1 5 0m2 1 2-2a3.5 3.5 0 0 1 5 5l-4 4a3.5 3.5 0 0 1-5 0"/>',article:'<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M8 8h8M8 12h8M8 16h5"/>',product:'<path d="M4 7h16l-1 14H5L4 7Z"/><path d="M8 8V6a4 4 0 0 1 8 0v2"/>',grid:'<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',list:'<path d="M9 5h12M9 12h12M9 19h12M3 5h1M3 12h1M3 19h1"/>',person:'<circle cx="12" cy="8" r="4"/><path d="M4 21v-2a8 8 0 0 1 16 0v2"/>',bookmark:'<path d="M6 3h12v18l-6-4-6 4V3Z"/>',logout:'<path d="M10 4H4v16h6M9 12h12m-5-5 5 5-5 5"/>',help:'<circle cx="12" cy="12" r="9"/><path d="M9 9a3 3 0 1 1 5 2c-1 1-2 1-2 3M12 17v1"/>',trash:'<path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7"/>'};
const icon = name => `<svg class="inline-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.link}</svg>`;
const name = () => account ? account.user_id.replace(/[-_]/g,' ').replace(/\b\w/g,c=>c.toUpperCase()) : 'Your space';
const date = value => new Date(value*1000).toLocaleDateString(undefined,{month:'short',day:'numeric'});
const kind = item => ['article','product'].includes(item.source) ? item.source : 'link';
const sourceLabel = item => item.has_image ? 'Saved image' : ({web:'Web link',article:'Article',product:'Product link',pinterest:'Pinterest',instagram:'Instagram'}[item.source] || 'Link');
function toast(message) { clearTimeout(toastTimer); $('#toast').textContent=message; $('#toast').hidden=false; toastTimer=setTimeout(()=>$('#toast').hidden=true,4200); }
function errorMessage(error) {
  if (error.status===401) return 'Your library needs an access key. Connect from Profile to continue.';
  if (error.status===410) return 'This save was removed. Close this sheet and refresh your library before starting a new save.';
  if (error.code==='network_error' || error.code==='request_timeout') return 'Couldn’t connect. Your details are kept here; try again when you’re back online.';
  if (error.code==='invalid_response' || error.status>=500) return 'We couldn’t confirm the result. Your details are kept here; please retry the same save.';
  if (error.code==='idempotency_conflict') return 'These details changed while saving. Close this sheet, refresh your library, and review the find before trying again.';
  return error.message || 'Something went wrong. Please try again.';
}
function header(title,subtitle,eyebrow='YOUR LITTLE CORNER') { return `<div class="page-header"><div><p class="eyebrow">${eyebrow}</p><h1>${title}</h1><p class="subtitle">${subtitle}</p></div>${view==='library' ? `<div class="header-actions"><button class="primary" data-action="add">${icon('plus')} Save a link</button></div>` : ''}</div>`; }
function empty(title,text,add=false) { return `<div class="empty-state"><div class="empty-art">${icon('bookmark')}<span>✳</span></div><h2>${title}</h2><p>${text}</p>${add ? `<button class="primary" data-action="${account ? 'add' : 'account'}">${icon('plus')} ${account ? 'Save your first link' : 'Connect your library'}</button>` : ''}</div>`; }
function card(item) {
  const known=Object.hasOwn(SOURCE_NAMES,item.source) ? item.source : 'web';
  return `<button class="save-card" data-action="detail" data-id="${escape(item.id)}" aria-label="Open ${escape(item.title)}"><div class="cover source-${known}"><div class="cover-top"><span class="source-pill">${sourceLabel(item)}</span>${icon('bookmark')}</div><div class="cover-glyph">${icon(kind(item))}</div><span class="cover-domain">${escape(sourceHost(item))}</span></div><div class="card-body"><span class="source-line">${escape(sourceHost(item))}</span><h3>${escape(item.title)}</h3>${item.note ? `<p class="card-note">${escape(item.note)}</p>` : ''}<div class="card-meta"><span>${date(item.captured_at)}</span><span>${icon('arrow')}</span></div></div></button>`;
}
function banner() { return loadError ? `<div class="error-banner" role="status">${escape(loadError)} <button class="text-button" data-action="${account ? 'refresh' : 'account'}">${account ? 'Try again' : 'Connect'}</button></div>` : loading ? '<p class="status-banner" role="status">Updating your library…</p>' : ''; }
function filters() {
  return `<div class="filters" aria-label="Filter saved content">${[['all','All saves'],...Object.entries(SOURCE_NAMES).filter(([key])=>items.some(i=>i.source===key))].map(([key,label])=>`<button class="filter ${source===key?'active':''}" data-source="${key}" aria-pressed="${source===key}">${label}${key==='all'?` <span>${items.length}</span>`:''}</button>`).join('')}</div>`;
}
function library() {
  const saved=visibleSaves(items,{source,sort});
  return header('Library','Everything you want to come back to.')+`<button class="search-entry" data-view="search">${icon('search')}<span>Find something you saved</span><span class="shortcut">⌘ K</span></button>`+banner()+`<div class="library-toolbar">${filters()}<div class="view-tools"><label class="sr-only" for="sort">Sort saved content</label><select id="sort"><option value="newest" ${sort==='newest'?'selected':''}>Newest first</option><option value="oldest" ${sort==='oldest'?'selected':''}>Oldest first</option><option value="title" ${sort==='title'?'selected':''}>Title A–Z</option></select><div class="segmented" aria-label="Library layout">${['grid','list'].map(value=>`<button data-layout="${value}" class="${layout===value?'active':''}" aria-label="${value==='grid'?'Grid':'List'} view" aria-pressed="${layout===value}">${icon(value)}</button>`).join('')}</div></div></div>`+(saved.length ? `<div class="library-grid ${layout==='list'?'list':''}">${saved.map(card).join('')}</div><p class="app-footer">A little less scrolling. A little more finding.</p>` : loading ? '' : empty(items.length?'Nothing here just yet.':'Your next good find starts here.',items.length?'Try another filter to see your saved links.':'The article, the idea, the thing you don’t want to forget. Keep it all in one place.',!items.length));
}
function searchResults() {
  const saved=visibleSaves(items,{query}), matches=query.trim() ? saved : saved.slice(0,6);
  $('#search-results').innerHTML=`<div class="section-heading"><h2>${query.trim()?'Search results':'Recently saved'}</h2><span class="count" role="status">${query.trim()?`${saved.length} ${saved.length===1?'find':'finds'}`:''}</span></div>`+(matches.length?`<div class="library-grid list">${matches.map(card).join('')}</div>`:empty(query.trim()?'No finds for that.':'Your finds will be right here.',query.trim()?'Try a word from the title, link, or a note you saved.':'Save a link to start your library.',!query.trim()));
  $('#clear-search').hidden=!query;
}
function search() { return header('Search','That thing you saved? It’s here.','FIND IT AGAIN')+`<div class="search-field">${icon('search')}<label class="sr-only" for="search-input">Search your saved content</label><input id="search-input" type="search" value="${escape(query)}" placeholder="Titles, notes, links…" autocomplete="off"><button id="clear-search" class="icon-button" data-action="clear-search" aria-label="Clear search">×</button></div>`+banner()+'<div id="search-results"></div>'; }
function setting(action,label,description,glyph,extra='') { return `<button class="settings-row ${extra}" data-action="${action}"><span class="row-icon">${icon(glyph)}</span><span class="row-copy"><strong>${label}</strong><small>${description}</small></span>${icon('chevron')}</button>`; }
function profile() {
  const sourceCount=new Set(items.map(sourceHost)).size;
  return header('Profile','A space that’s yours.','MYNAH FINDS')+`<section class="profile-card"><div class="avatar profile-avatar">${escape(name()[0])}</div><div class="profile-name"><h2>${escape(name())}</h2><p>${account?'Your personal library':'Keep your finds together'}</p></div><div class="profile-stats"><div><strong>${items.length}</strong><span>Saved finds</span></div><div><strong>${sourceCount}</strong><span>${sourceCount===1?'Source':'Sources'}</span></div></div></section><div class="settings-group">${setting('account',account?'Switch account':'Connect your library','Open your saved finds on this device','person')}${setting('help','Ways to save','From your browser or the iOS share sheet','bookmark')}${setting('refresh','Refresh library','Bring your latest saves into view','link')}</div>${account?`<div class="settings-group">${setting('signout','Sign out','Remove access from this browser session','logout','danger')}</div>`:''}${banner()}<p class="profile-footer">Mynah Finds<br><span>Good things, kept close.</span></p>`;
}
function render() {
  document.querySelectorAll('[data-view]').forEach(button=>{ const active=button.dataset.view===view; button.classList.toggle('active',active); active?button.setAttribute('aria-current','page'):button.removeAttribute('aria-current'); });
  $('#main').innerHTML = view==='search'?search():view==='profile'?profile():library();
  if (view==='search') searchResults();
  document.title=`Mynah Finds — ${view[0].toUpperCase()+view.slice(1)}`;
}
function go(next,focus=true) {
  if (!['library','search','profile'].includes(next)) return;
  view=next; history.replaceState(null,'',`#${view}`); render();
  window.scrollTo({top:0});
  if (focus) (view==='search'?$('#search-input'):$('#main')).focus({preventScroll:true});
}
async function refresh({fresh=false}={}) {
  if(fresh && refreshPromise) await refreshPromise;
  if (!token) { loading=false; render(); return; }
  if (refreshPromise) return refreshPromise;
  const revision=connectionRevision, api=client(), controller=new AbortController(); refreshController=controller;
  const promise=(async()=>{
    try {
      const [identity,saves]=await Promise.all([api.me({signal:controller.signal}),loadSavedLibrary(api,{signal:controller.signal})]);
      if (revision!==connectionRevision) return;
      account=identity; items=saves; loading=false; loadError='';
      if (!items.some(i=>i.source===source)) source='all';
    } catch(error) {
      if (revision!==connectionRevision || controller.signal.aborted) return;
      loading=false; loadError=errorMessage(error);
      if(error.status===401) { account=null; items=[]; }
    }
    if (revision===connectionRevision) {
      const active=$('#search-input')===document.activeElement, selection=active?$('#search-input').selectionStart:null;
      render();
      if(active) { $('#search-input').focus({preventScroll:true}); try { $('#search-input').setSelectionRange(selection,selection); } catch {} }
    }
  })();
  refreshPromise=promise;
  try { await promise; } finally { if(refreshPromise===promise) refreshPromise=null; }
}
function resetConnection({preserveCaptureFor=null}={}) {
  $('#detail-dialog').close();
  let pending=captureAttempt;
  if(!pending) { try { pending=JSON.parse(store.get('mymah-finds-capture')); } catch {} }
  connectionRevision++; accountIntent++; refreshController?.abort(); refreshPromise=null; captureAttempt=null; captureFlight=null; removeAttempt=null; removalAttempts.clear(); items=[]; account=null; query=''; source='all'; $('#capture-form').reset();
  $('#capture-form').querySelectorAll('input,textarea,select').forEach(field=>field.disabled=false);
  store.remove('mymah-finds-capture');
  if(preserveCaptureFor && pending?.accountId===preserveCaptureFor) { captureAttempt=pending;store.set('mymah-finds-capture',JSON.stringify(pending)); }
}
function rememberCapture(payload) {
  const fingerprint=JSON.stringify([location.origin,account?.user_id,payload]);
  if(!captureAttempt || captureAttempt.fingerprint!==fingerprint) captureAttempt={fingerprint,payload,key:newMutationKey(),accountId:account.user_id};
  store.set('mymah-finds-capture',JSON.stringify(captureAttempt)); return captureAttempt;
}
function openCapture() {
  if(!account) { $('#account-dialog').showModal(); return; }
  if($('#help-dialog').open) $('#help-dialog').close();
  if(!captureAttempt) { try { const saved=JSON.parse(store.get('mymah-finds-capture')); if(saved?.accountId===account.user_id && saved.key) captureAttempt=saved; } catch {} }
  if(captureAttempt) for(const [key,value] of Object.entries(captureAttempt.payload)) { const field=$(`#capture-form [name="${key}"]`); if(field) field.value=value; }
  $('#capture-status').textContent=captureFlight?'Saving to your library…':captureAttempt?.expired?'This earlier save was removed. Start a new save only if you want to keep this link again.':'';
  $('#new-save').hidden=!captureAttempt?.expired; $('#capture-form [type="submit"]').disabled=Boolean(captureAttempt?.expired || captureFlight);
  $('#capture-dialog').showModal();
}
function showDetail(id) {
  const item=items.find(item=>item.id===id); if(!item)return;
  const href=safeLink(item.original_url);
  $('#detail-content').innerHTML=`<div class="sheet-handle" aria-hidden="true"></div><div class="dialog-top"><span class="eyebrow">${escape(sourceLabel(item))}</span><button class="icon-button" data-close aria-label="Close">×</button></div><div class="detail-cover cover source-${Object.hasOwn(SOURCE_NAMES,item.source)?item.source:'web'}"><div class="cover-glyph">${icon(kind(item))}</div><span class="cover-domain">${escape(sourceHost(item))}</span></div><h2 id="detail-title">${escape(item.title)}</h2><p class="detail-meta">Saved ${date(item.captured_at)} · ${escape(sourceHost(item))}</p>${item.note?`<section class="detail-note"><h3>Your note</h3><p>${escape(item.note)}</p></section>`:''}${item.selected_text?`<section class="detail-note"><h3>Saved text</h3><p>${escape(item.selected_text)}</p></section>`:''}${href?`<a class="primary wide" href="${escape(href)}" target="_blank" rel="noopener noreferrer">Open original ${icon('arrow')}</a>`:''}<button class="text-button danger wide" data-action="remove" data-id="${escape(item.id)}">${icon('trash')} Remove from Library</button>`;
  $('#detail-dialog').showModal();
  if (item.has_image) $('#detail-content').querySelector('.detail-cover').hidden = true;
  const context = document.createElement('section'); context.className = 'detail-note saved-understanding';
  $('#detail-content').querySelector('.detail-meta').after(context);
  const revision = connectionRevision;
  showUnderstanding(context, item, {api: client(), scope: account.user_id,
    isCurrent: () => revision === connectionRevision && $('#detail-dialog').open,
    onSaved: updated => { items = items.map(current => current.id === updated.id ? updated : current); }});
}
document.addEventListener('click',async event=>{
  const close=event.target.closest('[data-close]'); if(close) { close.closest('dialog').close(); return; }
  const nav=event.target.closest('[data-view]'); if(nav) { go(nav.dataset.view); return; }
  const filter=event.target.closest('[data-source]'); if(filter) { source=filter.dataset.source;render();return; }
  const layoutButton=event.target.closest('[data-layout]'); if(layoutButton) { layout=layoutButton.dataset.layout;store.set('mymah-finds-layout',layout);render();return; }
  const button=event.target.closest('[data-action]'); if(!button)return;
  const action=button.dataset.action;
  if(action==='add')return openCapture();
  if(action==='new-save') { if(captureFlight)return;captureAttempt=null;store.remove('mymah-finds-capture');$('#new-save').hidden=true;$('#capture-status').textContent='Review the details, then save this link again.';$('#capture-form [type="submit"]').disabled=false;return; }
  if(action==='account')return $('#account-dialog').showModal();
  if(action==='help')return $('#help-dialog').showModal();
  if(action==='detail')return showDetail(button.dataset.id);
  if(action==='clear-search') { query='';$('#search-input').value='';searchResults();$('#search-input').focus();return; }
  if(action==='remove') { const id=button.dataset.id;if(!removalAttempts.has(id))removalAttempts.set(id,{id,key:newMutationKey()});removeAttempt=removalAttempts.get(id);$('#detail-dialog').close();$('#confirm-dialog').showModal();return; }
  if(action==='signout') { resetConnection();token='';store.set('mymah-finds-token','');store.remove('common-thread-token');loadError='';loading=false;render();toast('Signed out. Your saved finds are still in your library.');return; }
  if(action==='refresh') { button.disabled=true;await refresh();button.disabled=false;if(!loadError)toast('Your library is up to date.'); }
});
document.addEventListener('input',event=>{if(event.target.id==='search-input'){query=event.target.value;searchResults();}});
document.addEventListener('change',event=>{if(event.target.id==='sort'){sort=event.target.value;render();}});
document.addEventListener('submit',async event=>{
  event.preventDefault();const form=event.target;
  if(form.id==='capture-form' && (captureFlight || captureAttempt?.expired))return;
  const data=Object.fromEntries(new FormData(form)), submit=form.querySelector('[type="submit"]'), deletion=removeAttempt;
  const revision=connectionRevision, intent=form.id==='account-form'?++accountIntent:null;
  const flight=form.id==='capture-form'?{revision}:null;
  if(flight)captureFlight=flight;
  if(submit)submit.disabled=true;
  if(form.id==='capture-form')form.querySelectorAll('input,textarea,select').forEach(field=>field.disabled=true);
  try {
    if(form.id==='capture-form') {
      if(!account)throw new Error('Connect your library before saving.');
      const payload={...data,client:'web'};
      if(payload.source==='web') { const host=new URL(payload.url).hostname; if(/(^|\.)pinterest\./.test(host))payload.source='pinterest'; else if(/(^|\.)instagram\.com$/.test(host))payload.source='instagram'; }
      const attempt=rememberCapture(payload);
      $('#capture-status').textContent='Saving to your library…';
      const saved=await client().capture(attempt.payload,{idempotencyKey:attempt.key});
      if(revision!==connectionRevision)return;
      captureAttempt=null;store.remove('mymah-finds-capture');form.reset();$('#capture-dialog').close();await refresh({fresh:true});if(revision!==connectionRevision)return;go('library',false);
      toast(saved.duplicate?'Already in your library. Its existing note and details were kept.':'Saved to your library.');
    } else if(form.id==='account-form') {
      const provided=data.token.trim(),api=new CommonThreadClient({baseURL:location.origin,token:provided});
      const identity=await api.me();if(revision!==connectionRevision || intent!==accountIntent)return;
      resetConnection({preserveCaptureFor:identity.user_id});token=provided;store.set('mymah-finds-token',token);store.remove('common-thread-token');loadError='';loading=true;$('#account-dialog').close();form.reset();go('library',false);await refresh();
    } else if(form.id==='confirm-form' && deletion) {
      await client().deleteSave(deletion.id,{idempotencyKey:deletion.key});if(revision!==connectionRevision)return;
      removalAttempts.delete(deletion.id);
      if(removeAttempt===deletion){removeAttempt=null;$('#confirm-dialog').close();}
      await refresh({fresh:true});if(revision!==connectionRevision)return;toast('Removed from your library.');
    }
  } catch(error) {
    if(revision!==connectionRevision || (intent!==null && intent!==accountIntent))return;
    const message=errorMessage(error);
    if(form.id==='capture-form') {
      $('#capture-status').textContent=message;
      if(error.status===410 && captureAttempt){captureAttempt.expired=true;store.set('mymah-finds-capture',JSON.stringify(captureAttempt));$('#new-save').hidden=false;}
    } else if(form.id==='account-form')$('#account-status').textContent=message;else toast(message);
  } finally {
    if(flight && captureFlight===flight){captureFlight=null;form.querySelectorAll('input,textarea,select').forEach(field=>field.disabled=false);if(submit)submit.disabled=Boolean(captureAttempt?.expired);}
    if(submit && !flight)submit.disabled=false;
  }
});
$('#account-dialog').addEventListener('close',()=>{accountIntent++;$('#account-status').textContent='';});
window.addEventListener('hashchange',()=>go(location.hash.slice(1),false));
document.addEventListener('keydown',event=>{if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='k'&&!document.querySelector('dialog[open]')){event.preventDefault();go('search');}});
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&!document.querySelector('dialog[open]'))refresh();});
function syncViewport(){const viewport=window.visualViewport;if(viewport&&viewport.scale===1){document.documentElement.style.setProperty('--visual-height',`${viewport.height}px`);document.documentElement.style.setProperty('--keyboard-inset',`${Math.max(0,window.innerHeight-viewport.height-viewport.offsetTop)}px`);}}
window.visualViewport?.addEventListener('resize',syncViewport);window.visualViewport?.addEventListener('scroll',syncViewport);syncViewport();
render();await refresh();
