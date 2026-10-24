import test from 'node:test';
import assert from 'node:assert/strict';
import { applyAnswer, createSave, questionFor, safeUrl, refreshLocalQuestion } from '../questions.js';

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
  assert.equal(item.question.engine, 'local-rules-v2');
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

test('an Apple Watch product save must not become a cycling activity prompt', () => {
  const item = createSave({kind: 'page', title: 'Apple Watch Series 12 - Apple',
    url: 'https://www.apple.com/apple-watch-series-12/', excerpt: 'Cycling'});
  assert.notEqual(item.question.id, 'hobby-v1');
  assert.match(item.question.prompt, /Apple Watch/);
  assert.ok(!item.question.options.some(option => /friends|hobby|try it once/i.test(option.label)));
});

test('product metadata keeps unfamiliar products out of activity categories', () => {
  const item = createSave({kind: 'page', title: 'X1 Pro', contentType: 'product',
    url: 'https://example.com/x1', excerpt: 'Hiking and cycling', note: 'For camping'});
  assert.equal(item.question.id, 'product-v2');
  assert.match(item.question.prompt, /X1 Pro/);
});

test('a new watch image cannot inherit a previous room or activity question', () => {
  const first = createSave({kind: 'image', title: 'Warm room lighting', image: 'data:image/png;base64,AA=='});
  const next = createSave({kind: 'image', contentType: 'selected-image', title: 'Apple-Watch.png',
    excerpt: 'Hiking', image: 'data:image/png;base64,AQ=='});
  assert.equal(first.question.id, 'home-v1');
  assert.equal(next.question.id, 'product-v2');
  assert.match(next.question.prompt, /Apple-Watch/);
  assert.notDeepEqual(first.question.options, next.question.options);
  assert.match(next.question.basis, /image name/);
});

test('ambiguous page-body keywords do not invent an activity for an unidentified find', () => {
  const question = questionFor({title: 'X1 Pro', excerpt: 'Hiking, cycling and camping'});
  assert.equal(question.id, 'purpose-v1');
  assert.ok(!question.options.some(option => /friends|hobby|activity/i.test(option.label)));
  assert.equal(questionFor({title: 'Hiking with friends'}).id, 'hobby-v1');
  assert.equal(questionFor({title: 'My selection', excerpt: 'Hiking', textBasis: 'the text you selected'}).id, 'hobby-v1');
});

test('old basic prompts refresh without changing stored choices, images or pending upload keys', () => {
  const old = {title: 'Apple Watch Series 12 - Apple', excerpt: 'Cycling', kind: 'image', image: 'original-bytes',
    question: {engine: 'local-rules-v1', id: 'hobby-v1', prompt: 'How would you like to explore this activity?', options: []},
    answer: {kind: 'text', label: 'A gift for my brother', questionId: 'hobby-v1'},
    shared: {captureKey: 'original-key', payload: {note: 'original note'}}};
  const updated = refreshLocalQuestion(old);
  assert.equal(updated.question.id, 'product-v2');
  assert.deepEqual(updated.answer, old.answer); assert.equal(updated.image, old.image);
  assert.deepEqual(updated.shared, old.shared); assert.equal(old.question.id, 'hobby-v1');
  assert.equal(applyAnswer(updated, {optionId: 'compare'}).answer.label, 'Price and alternatives');
  const ai = {...old, question: {engine: 'shared', prompt: 'Which strap colour caught your eye?'}};
  assert.equal(refreshLocalQuestion(ai), ai);
});
