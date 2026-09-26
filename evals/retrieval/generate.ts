// Builds the retrieval eval image set from CC0 / public-domain photos via the Openverse API
// (Nova Canvas is LEGACY in this account, and no other first-party image model is active — see D-104).
// Usage (from backend/): npx tsx ../evals/retrieval/generate.ts
// Then check evals/retrieval/contact-sheet.jpg and override bad picks with "pick": <index> or a better "search".
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const here = path.dirname(fileURLToPath(import.meta.url));
const data = JSON.parse(readFileSync(path.join(here, 'dataset.json'), 'utf8'));
const creditsPath = path.join(here, 'CREDITS.json');
const credits: Record<string, unknown> = existsSync(creditsPath) ? JSON.parse(readFileSync(creditsPath, 'utf8')) : {};

const STOP = new Set(['my', 'the', 'i', 'a', 'our', 'at', 'on', 'in', 'up', 'to', 'of', 'made', 'got', 'from', 'with', 'last', 'that', 'all', 'new', 'for']);
const searchTerm = (img: any) => img.search ?? img.query.split(/\s+/).filter((w: string) => !STOP.has(w.toLowerCase())).join(' ');

async function download(url: string): Promise<Buffer | undefined> {
  try {
    const r = await fetch(url, { headers: { 'user-agent': 'nudge-evals/1.0' }, signal: AbortSignal.timeout(20_000) });
    if (!r.ok) return undefined;
    return Buffer.from(await r.arrayBuffer());
  } catch {
    return undefined;
  }
}

for (const img of data.images) {
  const out = path.join(here, 'images', `${img.id}.jpg`);
  if (existsSync(out) && !process.argv.includes('--force') && !process.argv.includes(img.id)) continue;
  const q = encodeURIComponent(searchTerm(img));
  const res = await fetch(`https://api.openverse.org/v1/images/?q=${q}&license=cc0,pdm&page_size=10&mature=false`, {
    headers: { 'user-agent': 'nudge-evals/1.0' },
  });
  const results = (((await res.json()) as any).results ?? []) as any[];
  let saved = false;
  for (let i = img.pick ?? 0; i < results.length && !saved; i++) {
    const r = results[i];
    const bytes = (await download(r.url)) ?? (r.thumbnail ? await download(r.thumbnail) : undefined);
    if (!bytes) continue;
    try {
      const jpg = await sharp(bytes).rotate().resize(768, 768, { fit: 'inside' }).jpeg({ quality: 80 }).toBuffer();
      writeFileSync(out, jpg);
      credits[img.id] = { title: r.title, creator: r.creator, license: r.license, source: r.foreign_landing_url ?? r.url };
      saved = true;
      console.log('saved', img.id, '←', r.title);
    } catch {}
  }
  if (!saved) console.warn('NO IMAGE for', img.id, searchTerm(img));
  await new Promise((r) => setTimeout(r, 400)); // be polite to the API
}
writeFileSync(creditsPath, JSON.stringify(credits, null, 2));

// Contact sheet for a quick visual check of labels.
const ids = data.images.map((i: any) => i.id).filter((id: string) => existsSync(path.join(here, 'images', `${id}.jpg`)));
const cell = 160;
const cols = 10;
const rows = Math.ceil(ids.length / cols);
const tiles = await Promise.all(
  ids.map(async (id: string, k: number) => {
    const label = Buffer.from(
      `<svg width="${cell}" height="18"><rect width="100%" height="100%" fill="black"/><text x="3" y="13" font-size="12" fill="white" font-family="Helvetica">${id}</text></svg>`,
    );
    const tile = await sharp(path.join(here, 'images', `${id}.jpg`))
      .resize(cell, cell, { fit: 'cover' })
      .composite([{ input: label, top: cell - 18, left: 0 }])
      .toBuffer();
    return { input: tile, left: (k % cols) * cell, top: Math.floor(k / cols) * cell };
  }),
);
await sharp({ create: { width: cols * cell, height: rows * cell, channels: 3, background: '#ffffff' } })
  .composite(tiles)
  .jpeg({ quality: 70 })
  .toFile(path.join(here, 'contact-sheet.jpg'));
console.log(`images: ${ids.length}/${data.images.length}`);
