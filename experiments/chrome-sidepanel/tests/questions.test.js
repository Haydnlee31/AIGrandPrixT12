import test from 'node:test';
import assert from 'node:assert/strict';
import { applyAnswer, createSave, questionFor, safeUrl } from '../questions.js';

test('a user note takes precedence over the page topic', () => {
  const result = questionFor({ title: 'A beautiful bakery', note: 'Only the warm lighting' });
  assert.equal(result.id, 'home-v1');
  assert.ok(result.options.some(option => option.id === 'inspiration'));
});

test('a bakery save asks purpose without assuming equipment buying', () => {
  const result = questionFor({ title: 'Bakery worth a visit' });
  assert.equal(result.id, 'food-v1');
  assert.equal(result.options.find(o => o.id === 'visit').label, 'Try it myself');
});

test('unidentified screenshot stays a general question and never claims image understanding', () => {
  const item = createSave({ kind: 'image', title: 'IMG_234.jpg', image: 'data:image/jpeg;base64,AA==' });
  assert.equal(item.question.id, 'purpose-v1');
  assert.equal(item.question.engine, 'local-rules-v1');
  assert.equal(item.answer, null);
  assert.equal(item.url, null);
});

test('only safe source URLs are accepted', () => {
  for (const value of ['javascript:alert(1)', 'file:///etc/passwd', 'chrome://settings', 'https://name:secret@example.com', 'not a url']) assert.equal(safeUrl(value), null);
  assert.equal(safeUrl('https://example.com/lamp'), 'https://example.com/lamp');
  assert.throws(() => createSave({ kind: 'page', url: 'javascript:alert(1)' }));
  assert.throws(() => createSave({ kind: 'image', image: 'data:image/svg+xml;base64,AA==' }));
});

test('answers persist user choice, allow correction and do not mutate source', () => {
  const item = createSave({ kind: 'page', url: 'https://example.com', title: 'Small room ideas' });
  const answered = applyAnswer(item, { optionId: 'lighting' });
  assert.equal(answered.answer.optionId, 'lighting');
  assert.equal(item.answer, null);
  const changed = applyAnswer(answered, { text: 'Only storage, under $100' });
  assert.equal(changed.answer.kind, 'text');
  assert.equal(changed.answer.label, 'Only storage, under $100');
  assert.equal(changed.question.id, item.question.id);
  assert.equal(changed.id, item.id);
});

test('skip is distinct from preference and invalid responses fail', () => {
  const item = createSave({ kind: 'page', url: 'https://example.com' });
  assert.equal(applyAnswer(item, { skip: true }).answer.kind, 'skipped');
  assert.throws(() => applyAnswer(item, { optionId: 'invented' }));
  assert.throws(() => applyAnswer(item, { text: '   ' }));
  assert.throws(() => applyAnswer(item, { text: 'x'.repeat(501) }));
});

test('the real NParks title offers birdwatching intents without a note', () => {
  const item = createSave({ kind: 'page', title: 'How Now Brown Bird?', url: 'https://www.nparks.gov.sg/publications-resources/articles/how-now-brown-bird' });
  assert.equal(item.question.id, 'birdwatching-v1');
  assert.ok(item.question.options.some(o => o.id === 'gear'));
  assert.ok(item.question.options.some(o => o.id === 'inspiration'));
  assert.equal(applyAnswer(item, { optionId: 'gear' }).answer.label, 'Explore binoculars for birdwatching');
});
test('social captions provide creative intents without claiming video understanding', () => {
  const question = questionFor({ title: 'Instagram', excerpt: 'A young swordsman challenged a master. #claymation #stopmotion #animation', textBasis: 'the post caption, not the video or audio' });
  assert.equal(question.id, 'creative-v1');
  assert.match(question.basis, /not the video/);
});
test('conversation type offers one-tap intents without inventing image contents', () => {
  const item = createSave({ kind: 'image', contentType: 'conversation', title: 'sample-conversation.png', image: 'data:image/png;base64,AA==' });
  assert.equal(item.question.id, 'conversation-v1');
  assert.match(item.question.basis, /not the words in the image/);
  assert.equal(applyAnswer(item, { optionId: 'place' }).answer.optionId, 'place');
});

test('multiple intents are additive, skip preserves them, and local removal targets one', () => {
  let item = createSave({kind:'page', title:'Small room ideas', url:'https://example.org/room'});
  item = applyAnswer(item, {optionId:'lighting'});
  item = applyAnswer(item, {optionId:'layout'});
  assert.equal(item.intents.length, 2);
  item = applyAnswer(item, {optionId:'lighting'});
  assert.equal(item.intents.length, 2);
  item = applyAnswer(item, {skip:true});
  assert.equal(item.intents.length, 2);
  const removed = applyAnswer(item, {removeIntentId:item.intents[0].id});
  assert.equal(removed.intents.length, 1);
  assert.equal(removed.intents[0].optionId, 'layout');
  assert.ok(!removed.pendingAnswers.some(answer => answer.optionId === 'lighting'));
});
