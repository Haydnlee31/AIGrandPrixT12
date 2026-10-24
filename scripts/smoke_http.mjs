import assert from 'node:assert/strict';
import {CommonThreadClient, newMutationKey} from '../clients/javascript/client.js';

const api = new CommonThreadClient({baseURL:process.env.SMOKE_API_URL, token:process.env.SMOKE_API_TOKEN});
const mutation = () => ({idempotencyKey:newMutationKey()});
assert.equal((await api.health()).status,'ok');
assert.equal((await api.capabilities()).contract_version,'0.3.0');
const payload = {url:'https://example.org/chrome-desk',title:'Warm desk lighting',note:'Warm lighting for my small desk',client:'chrome_extension'};
const captureKey = mutation();
const receipt = await api.capture(payload,captureKey);
assert.deepEqual(await api.capture(payload,captureKey),receipt);
const chromeItem = await api.waitForSave(receipt.id,{intervalMs:100});
assert.equal(chromeItem.client,'chrome_extension');
assert.equal(chromeItem.status,'ready');
await api.respond(chromeItem.id,{action:'select',suggestion_id:chromeItem.suggestions[0].id},mutation());
await api.capture({url:'https://example.org/ios-desk',title:'Small desk',client:'ios_share_extension'},mutation());
assert.deepEqual(new Set((await api.collection()).items.map(item=>item.client)),new Set(['chrome_extension','ios_share_extension']));
assert.ok((await api.hypotheses()).items[0].evidence.length);
const discovery = await api.startDiscovery({explicit:true},mutation());
const updated = await api.discoveryEvent(discovery.id,{action:'budget',value:10000,expected_version:discovery.version},mutation());
await assert.rejects(api.discoveryEvent(discovery.id,{action:'direction',value:'warm',expected_version:discovery.version},mutation()),error=>error.code==='stale_version' && error.current.version===updated.version);
const shortlist = await api.discoveryEvent(discovery.id,{action:'retrieve',expected_version:updated.version},mutation());
assert.ok(shortlist.products.length);
const watch = await api.createWatch({variant_id:'halo-cream',target_minor:7000},mutation());
const queued = await api.simulatePrice(watch.id,{variant_id:'halo-cream',currency:'SGD',amount_minor:6900},mutation());
for (let attempt=0;attempt<100;attempt++) {
  const job = await api.getJob(queued.job_id);
  if (job.status==='done') break;
  assert.notEqual(job.status,'failed');
  if (attempt===99) throw new Error('Worker job did not complete');
  await new Promise(resolve=>setTimeout(resolve,100));
}
assert.equal((await api.notifications()).items.length,1);
assert.equal((await api.getWatch(watch.id)).last_price_minor,6900);
await api.deleteSave(receipt.id,mutation());
await assert.rejects(api.capture(payload,captureKey),error=>error.status===410 && error.code==='mutation_expired');
assert.equal((await api.collection()).items.length,1);
console.log('HTTP smoke passed: shared SDK → migrated API → worker → cross-client collection, annotation, session conflict, watch alert, deletion/retry.');
