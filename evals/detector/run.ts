// Reference detector eval (SPEC REF-2). Calls the production detectReference with the production
// confidence gate. Usage (from backend/): npx tsx ../evals/detector/run.ts
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { detectReference } from '../../backend/src/ai/detector.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const data = JSON.parse(readFileSync(path.join(here, 'dataset.json'), 'utf8'));
const MIN_CONFIDENCE = 0.5; // same gate as src/lib/references.ts
const now = new Date('2026-09-26T18:00:00Z');

const rows: any[] = [];
const latencies: number[] = [];
const cases = data.cases as { id: string; kind: string; label: boolean; lines: [string, string][] }[];
// Small concurrency to keep it quick without hammering the API.
const queue = [...cases];
await Promise.all(
  Array.from({ length: 4 }, async () => {
    for (let c = queue.shift(); c; c = queue.shift()) {
      const segments = c.lines.map(([who, text]) => ({ userId: who === 'S' ? 'speaker' : 'friend', text }));
      const t0 = Date.now();
      const d = await detectReference(segments, 'speaker', now);
      latencies.push(Date.now() - t0);
      const predicted = d.isReference && d.confidence >= MIN_CONFIDENCE;
      rows.push({ id: c.id, kind: c.kind, label: c.label, predicted, query: d.query, confidence: d.confidence, dateHint: d.dateHint });
    }
  }),
);

rows.sort((a, b) => a.id.localeCompare(b.id));
const tp = rows.filter((r) => r.label && r.predicted).length;
const fp = rows.filter((r) => !r.label && r.predicted).length;
const fn = rows.filter((r) => r.label && !r.predicted).length;
const precision = tp / (tp + fp || 1);
const recall = tp / (tp + fn || 1);
const hardFp = rows.filter((r) => r.kind === 'hard' && r.predicted).length;
const s = [...latencies].sort((a, b) => a - b);
const pct = (p: number) => s[Math.min(s.length - 1, Math.floor(p * s.length))];

mkdirSync(path.join(here, 'out'), { recursive: true });
writeFileSync(path.join(here, 'out', 'detector-results.json'), JSON.stringify({ precision, recall, tp, fp, fn, rows }, null, 2));
console.log(`cases ${rows.length}  TP ${tp}  FP ${fp} (hard-negative FP ${hardFp})  FN ${fn}`);
console.log(`precision ${precision.toFixed(3)}  recall ${recall.toFixed(3)}  (targets ≥0.85 / ≥0.60)`);
console.log(`detector latency p50 ${pct(0.5)} ms  p95 ${pct(0.95)} ms`);
for (const r of rows.filter((r) => r.label !== r.predicted)) console.log(`  ${r.label ? 'FN' : 'FP'} ${r.id} conf=${r.confidence} q="${r.query}"`);
