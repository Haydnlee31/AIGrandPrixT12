const option = (id, label, next) => ({ id, label, next });
const inspiration = option('inspiration', 'Just keeping the inspiration', 'Kept as inspiration. No shopping task or price watch has been started.');

const conversation = {
  id: 'conversation', prompt: 'What would you like to keep from this conversation?',
  options: [option('place', 'Try a place someone mentioned', 'You want to revisit a place from the conversation. Its name and details still need checking.'), option('product', 'Look into a recommended product', 'You want to explore a recommendation. The screenshot has not been read or the product identified.'), option('together', 'Plan something together', 'Focus saved: a shared plan. No booking or purchase has been made.'), inspiration]
};
const topics = [
  {
    id: 'birdwatching', matches: /\b(birds?|birdwatching|birding|binoculars?|sparrows?|mynahs?|mynas?)\b/i,
    prompt: 'What interests you about this bird find?',
    options: [option('learn', 'Learn to recognise these birds', 'You want to learn about the birds. No purchase is needed to keep exploring.'), option('gear', 'Explore binoculars for birdwatching', 'Focus saved: birdwatching binoculars. No product, price or suitability has been verified.'), option('outing', 'Plan a birdwatching outing', 'Focus saved: an outing. Location, time and who is coming can guide a later plan.'), inspiration]
  },
  {
    id: 'creative', matches: /\b(claymation|stopmotion|stop.motion|animation)\b/i,
    prompt: 'What would you like to take from this creative idea?',
    options: [option('try', 'Try making something like this', 'Focus saved: a first creative experiment. No assumption that you need new equipment.'), option('learn', 'Learn how it was made', 'You want to explore the technique. This is based on the caption, not an analysis of the video.'), option('friends', 'Make something with friends', 'Focus saved: a shared creative activity. Supplies can be considered after choosing a project.'), inspiration]
  },
  {
    id: 'home', matches: /\b(room|interior|renovation|reno|furniture|lighting|lamp|shelving|shelf|sofa|bedroom|desk|decor|décor|rental)\b/i,
    prompt: 'What would you like to bring into your own space?',
    options: [option('lighting', 'The lighting & atmosphere', 'Focus saved: lighting and atmosphere. This does not mean you want the furniture.'), option('layout', 'The layout or storage', 'Focus saved: layout and storage. Room size and what you already own can guide the next step.'), option('item', 'A particular item', 'Focus saved: a particular item. Its exact identity still needs to be checked.'), inspiration]
  },
  {
    id: 'style', matches: /\b(outfit|fashion|dress|jacket|sneakers?|shoes?|clothes|clothing|wardrobe|jeans)\b/i,
    prompt: 'What would you like to take from this look?',
    options: [option('exact', 'Find a particular piece', 'You want to explore a particular piece. An exact product match has not been verified.'), option('version', 'Make it my own', 'Focus saved: adapt the look to your own style, rather than copy every item.'), option('occasion', 'Plan for an occasion', 'Focus saved: an occasion. The event and what you already own can shape a later shortlist.'), inspiration]
  },
  {
    id: 'food', matches: /\b(bakery|bakeries|cafe|café|restaurant|pastry|pastries|cake|croissant|bread|recipe|baking|cooking)\b/i,
    prompt: 'What would you like to do with this food find?',
    options: [option('visit', 'Try it myself', 'You saved this to try yourself. No assumption that you want cooking equipment.'), option('together', 'Share it with someone', 'Focus saved: enjoy it with someone. A place or occasion can guide the next step.'), option('make', 'Try making it', 'You want to try making it. Check what you already have before considering supplies.'), inspiration]
  },
  {
    id: 'hobby', matches: /\b(hobby|pottery|ceramics|hiking|camping|climbing|painting|knitting|crochet|gardening|cycling|workshop)\b/i,
    prompt: 'How would you like to explore this activity?',
    options: [option('try', 'Try it once', 'Focus saved: a low-commitment first try. Borrowing, renting or a class may be enough.'), option('friends', 'Do it with friends', 'Focus saved: a shared activity. Group needs can come before an equipment list.'), option('learn', 'Get into the hobby', 'Focus saved: learning the hobby. Beginner needs and existing supplies can guide a later plan.'), inspiration]
  }
];

function productQuestion(title, contentType) {
  // A named object outranks incidental hobbies mentioned in its marketing copy.
  if (contentType !== 'product' && !/\b(apple watch|smartwatch(?:es)?|fitness tracker|iphone|ipad|airpods?|macbook|smartphone|headphones?|earbuds?|laptop|camera|monitor|keyboard|headset|vacuum)\b/i.test(title.replace(/[_-]/g, ' '))) return null;
  const name = title.replace(/\s[-–—|]\s.*$/, '').replace(/\.(png|jpe?g|webp)$/i, '').trim().slice(0, 100) || 'this product';
  return {id: 'product', prompt: `What matters to you about ${name}?`, options: [
    option('usage', 'How I would use it', `You want to consider how ${name} would fit your everyday use. Its features still need checking.`),
    option('design', 'The design and fit', `You want to explore the design and fit of ${name}. No dimensions or compatibility have been verified.`),
    option('compare', 'Price and alternatives', `You want to compare ${name} with other options. No current price or product match has been verified.`), inspiration]};
}

export function questionFor({ title = '', excerpt = '', note = '', kind = 'page', contentType = '', textBasis = '' }) {
  // shortcut: text-only fallback; shared AI supplies content-specific visual prompts when connected.
  const match = (value) => topics.find(topic => topic.matches.test(value));
  // A full page can mention many unrelated activities; only use a caption or an
  // explicit text selection as a topic source, never arbitrary page-body keywords.
  const focusedText = contentType === 'social' || /post caption|text you selected/.test(textBasis);
  const topic = (contentType === 'conversation' ? conversation : productQuestion(title, contentType))
    || match(note) || match(title) || (focusedText ? match(excerpt) : null);
  return {
    id: `${topic?.id || 'purpose'}-${topic?.id === 'product' ? 'v2' : 'v1'}`,
    engine: 'local-rules-v2',
    basis: contentType === 'conversation' ? 'the conversation type you chose, not the words in the image' : textBasis || (kind === 'image' ? 'your note and the image name' : 'the page text and your note'),
    prompt: topic?.prompt || 'What would make this save useful to you?',
    options: topic?.options || [option('find', 'Find something like this', 'You want to explore similar options. No product identity or current price has been verified.'), option('version', 'Make it my version', 'You want to adapt this idea. Your own space, style or constraints can shape the next step.'), option('learn', 'Learn more about it', 'You want to understand this find better. Its contents have not been visually analysed.'), inspiration]
  };
}

/** Refresh old basic prompts on read; preserve AI prompts and every saved answer. */
export function refreshLocalQuestion(item) {
  return item?.question?.engine?.startsWith('local-rules-') ? {...item, question: questionFor(item)} : item;
}

export function safeUrl(value) {
  try {
    const url = new URL(value);
    return ['http:', 'https:'].includes(url.protocol) && !url.username && !url.password ? url.href : null;
  } catch { return null; }
}

export function createSave(input) {
  if (!['page', 'screenshot', 'image'].includes(input.kind)) throw new Error('Unsupported capture type.');
  if (input.kind !== 'image' && !safeUrl(input.url)) throw new Error('Open a regular website, then click the Mynah Finds toolbar icon to allow access to that page.');
  if (input.kind !== 'page' && !/^data:image\/(jpeg|png|webp);base64,/.test(input.image || '')) throw new Error('The screenshot could not be read. Please try again.');
  const saved = {
    id: crypto.randomUUID(),
    kind: input.kind,
    contentType: ['conversation', 'social', 'article', 'product', 'selected-image'].includes(input.contentType) ? input.contentType : '',
    textBasis: String(input.textBasis || '').slice(0, 200),
    imageCapture: input.imageCapture === 'visible-crop' ? 'visible-crop' : input.imageCapture === 'image' ? 'image' : '',
    imageUrl: safeUrl(input.imageUrl),
    url: safeUrl(input.url),
    title: String(input.title || 'Untitled save').slice(0, 240),
    excerpt: String(input.excerpt || '').slice(0, 6000),
    note: String(input.note || '').trim().slice(0, 500),
    image: input.kind === 'page' ? null : input.image,
    createdAt: new Date().toISOString(),
    answer: null
  };
  saved.question = questionFor(saved);
  return saved;
}

export function applyAnswer(item, { optionId, text, skip = false }) {
  let answer;
  if (skip) answer = { kind: 'skipped', label: 'Not now', next: 'Saved for later. You can add context whenever you like.' };
  else if (optionId) {
    const selected = item.question.options.find(o => o.id === optionId);
    if (!selected) throw new Error('That answer is no longer available. Reopen this save and try again.');
    answer = { kind: 'choice', optionId, label: selected.label, next: selected.next };
  } else {
    const value = String(text || '').trim();
    if (!value || value.length > 500) throw new Error('Add a short answer of up to 500 characters.');
    answer = { kind: 'text', label: value, next: 'Your own words are saved with this item. They have not been turned into a global preference.' };
  }
  return { ...item, answer: { ...answer, questionId: item.question.id, answeredAt: new Date().toISOString() }, updatedAt: new Date().toISOString() };
}
