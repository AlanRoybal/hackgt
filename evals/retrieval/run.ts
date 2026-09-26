// Retrieval eval (SPEC REF-3): top-1/top-3 of query → photo, and similarity threshold tuning.
// Uses the production caption + embedding modules. Usage (from backend/): npx tsx ../evals/retrieval/run.ts
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { captionImage } from '../../backend/src/ai/caption.js';
import { cosine, embedImage, embedText } from '../../backend/src/ai/embed.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const data = JSON.parse(readFileSync(path.join(here, 'dataset.json'), 'utf8'));
const outDir = path.join(here, 'out');
mkdirSync(outDir, { recursive: true });
const cachePath = path.join(outDir, 'cache.json');
const cache: Record<string, any> = existsSync(cachePath) ? JSON.parse(readFileSync(cachePath, 'utf8')) : {};
const save = () => writeFileSync(cachePath, JSON.stringify(cache));

async function cached<T>(key: string, fn: () => Promise<T>): Promise<T> {
  if (!(key in cache)) {
    cache[key] = await fn();
    save();
  }
  return cache[key];
}

type Strategy = 'fused' | 'image' | 'caption';
const vecs: Record<Strategy, Record<string, number[]>> = { fused: {}, image: {}, caption: {} };
for (const img of data.images) {
  const bytes = readFileSync(path.join(here, 'images', `${img.id}.jpg`));
  const caption = await cached(`caption:${img.id}`, () => captionImage(bytes));
  img.caption = caption;
  vecs.fused[img.id] = await cached(`fused:${img.id}`, () => embedImage(bytes, caption));
  vecs.image[img.id] = await cached(`image:${img.id}`, () => embedImage(bytes));
  vecs.caption[img.id] = await cached(`captext:${img.id}`, () => embedText(caption));
}

const qv = async (q: string) => cached(`q:${q}`, () => embedText(q));

const report: string[] = [];
const results: Record<string, any> = {};
for (const strat of ['fused', 'image', 'caption'] as Strategy[]) {
  let top1 = 0;
  let top3 = 0;
  const posSims: number[] = [];
  const misses: string[] = [];
  for (const img of data.images) {
    const q = await qv(img.query);
    const ranked = Object.entries(vecs[strat])
      .map(([id, v]) => ({ id, s: cosine(q, v) }))
      .sort((a, b) => b.s - a.s);
    const rank = ranked.findIndex((r) => r.id === img.id);
    if (rank === 0) top1++;
    if (rank < 3) top3++;
    else misses.push(`${img.id} ("${img.query}") → rank ${rank + 1}, top: ${ranked[0].id}`);
    posSims.push(ranked[rank].s);
  }
  const negSims: number[] = [];
  for (const q of data.negatives) {
    const v = await qv(q);
    negSims.push(Math.max(...Object.values(vecs[strat]).map((x) => cosine(v, x))));
  }
  // Threshold that maximizes TPR − FPR (Youden's J) over candidate cut points.
  let best = { t: 0, j: -Infinity, tpr: 0, fpr: 0 };
  for (let t = 0; t <= 0.8; t += 0.005) {
    const tpr = posSims.filter((s) => s >= t).length / posSims.length;
    const fpr = negSims.filter((s) => s >= t).length / negSims.length;
    if (tpr - fpr > best.j) best = { t: Number(t.toFixed(3)), j: tpr - fpr, tpr, fpr };
  }
  const n = data.images.length;
  results[strat] = { top1: top1 / n, top3: top3 / n, threshold: best, posSims, negSims, misses };
  report.push(
    `${strat.padEnd(8)} top-1 ${(top1 / n).toFixed(3)}  top-3 ${(top3 / n).toFixed(3)}  ` +
      `threshold ${best.t} (TPR ${best.tpr.toFixed(2)}, FPR ${best.fpr.toFixed(2)})  ` +
      `pos sim median ${median(posSims).toFixed(3)}  neg max-sim median ${median(negSims).toFixed(3)}`,
  );
}
function median(a: number[]) {
  const s = [...a].sort((x, y) => x - y);
  return s[Math.floor(s.length / 2)];
}

writeFileSync(path.join(outDir, 'retrieval-results.json'), JSON.stringify(results, null, 2));
console.log(report.join('\n'));
console.log('\nfused misses (outside top-3):\n' + results.fused.misses.join('\n'));
