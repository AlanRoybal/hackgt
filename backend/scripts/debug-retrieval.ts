// Replays the integ reference sentences through detector → embed → cosine vs cached eval image embeddings.
import { readFileSync } from 'node:fs';
import { detectReference } from '../src/ai/detector.js';
import { cosine, embedText } from '../src/ai/embed.js';

const cache = JSON.parse(readFileSync('../evals/retrieval/out/cache.json', 'utf8'));
const PHOTOS = ['dog-beach', 'lasagna', 'cake-birthday', 'eiffel', 'kayak', 'sushi', 'dog-couch'];
const S: [string, string][] = [
  ['lasagna', 'Oh my god, I made the most amazing lasagna last night, it was huge.'],
  ['dog-beach', 'We took the dog to the beach this morning and she ran into every wave.'],
  ['cake-birthday', 'I baked a chocolate birthday cake with candles for my birthday on Tuesday.'],
  ['eiffel', 'When we were in Paris last week we went up the Eiffel Tower.'],
  ['kayak', 'We went kayaking on the lake yesterday, the water was so calm.'],
  ['sushi', 'We had a giant sushi platter with salmon for dinner Friday.'],
];
const ctx: { userId: string; text: string }[] = [{ userId: 'f', text: 'So what did you get up to this week?' }];
for (const [id, text] of S) {
  ctx.push({ userId: 's', text });
  const d = await detectReference(process.argv.includes('--context') ? ctx : [{ userId: 's', text }], 's');
  const v = await embedText([d.query, d.placeHint].filter(Boolean).join(', '));
  const ranked = PHOTOS.map((p) => ({ p, s: cosine(v, cache[`image:${p}`]) })).sort((a, b) => b.s - a.s);
  console.log(id.padEnd(14), JSON.stringify(d.query), JSON.stringify(d.dateHint), ranked.slice(0, 3).map((r) => `${r.p}:${r.s.toFixed(3)}`).join('  '));
}
