// PHO-1..6 and REF-1..11 against the deployed dev stage: real upload → Rekognition → Nova → Titan → S3 Vectors,
// then transcript over WebSocket → detector → retrieval → photo.suggestion, and share URLs.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { GetVectorsCommand, S3VectorsClient } from '@aws-sdk/client-s3vectors';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { ApiError, befriend, call, cleanup, makeUser, OUTPUTS, openSocket, sleep, until, type TestUser } from './client.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const img = (id: string) => readFileSync(path.join(here, '..', '..', 'evals', 'retrieval', 'images', `${id}.jpg`));
const fixture = (id: string) => readFileSync(path.join(here, '..', '..', 'evals', 'safety', 'fixtures', `${id}.jpg`));
const run = Math.random().toString(36).slice(2, 8);
const hash = (id: string) => `it${run}${id.replace(/[^a-z0-9]/gi, '')}`;

const PHOTOS = ['dog-beach', 'lasagna', 'cake-birthday', 'eiffel', 'kayak', 'sushi'];
const REFERENCES: [string, string][] = [
  ['lasagna', 'Oh my god, I made the most amazing lasagna last night, it was huge.'],
  ['dog-beach', 'We took the dog to the beach this morning and she ran into every wave.'],
  ['cake-birthday', 'I baked a chocolate birthday cake with candles for my birthday on Tuesday.'],
  ['eiffel', 'When we were in Paris last week we went up the Eiffel Tower.'],
  ['kayak', 'We went kayaking on the lake yesterday, the water was so calm.'],
  ['sushi', 'We had a giant sushi platter with salmon for dinner Friday.'],
];

let a: TestUser;
let b: TestUser;
let callId: string;
const latencies: number[] = [];

async function upload(u: TestUser, items: { id: string; bytes: Buffer; takenAt?: string; isScreenshot?: boolean }[]) {
  const r = await u.req('POST', '/photos/uploads', {
    items: items.map((i) => ({
      assetHash: hash(i.id),
      takenAt: i.takenAt ?? new Date(Date.now() - 2 * 86_400_000).toISOString(),
      isScreenshot: !!i.isScreenshot,
      width: 768,
      height: 768,
      place: undefined,
    })),
  });
  for (const up of r.uploads) {
    const item = items.find((i) => hash(i.id) === up.assetHash)!;
    const put = await fetch(up.uploadUrl, { method: 'PUT', headers: { 'content-type': 'image/jpeg' }, body: item.bytes });
    expect(put.ok).toBe(true);
  }
  return r;
}

beforeAll(async () => {
  a = await makeUser('pha');
  b = await makeUser('phb');
  await befriend(a, b);
});
afterAll(() => cleanup(a, b));

describe('photo index', () => {
  it('PHO-1/2/3/5: last-30-days selection, safety exclusion, and indexing', async () => {
    const r = await upload(a, [
      ...PHOTOS.map((id) => ({ id, bytes: img(id) })),
      { id: 'card', bytes: fixture('card') },
      { id: 'old', bytes: img('ramen'), takenAt: new Date(Date.now() - 40 * 86_400_000).toISOString() },
      { id: 'shot', bytes: fixture('menu'), isScreenshot: true },
    ]);
    expect(r.skipped.sort()).toEqual([hash('old'), hash('shot')].sort());
    expect(r.uploads.length).toBe(PHOTOS.length + 1);
    const status = await until(
      async () => {
        const s = await a.req('GET', '/photos/status');
        return s.pending === 0 ? s : undefined;
      },
      120_000,
      2000,
    );
    expect(status).toMatchObject({ indexed: PHOTOS.length, excluded: 1, failed: 0 });
    // Re-announcing the same photos is a no-op.
    const again = await a.req('POST', '/photos/uploads', {
      items: [{ assetHash: hash('lasagna'), takenAt: new Date().toISOString(), isScreenshot: false, width: 1, height: 1 }],
    });
    expect(again.uploads).toEqual([]);
  });
});

describe('in-call references', () => {
  it('sets up a call', async () => {
    const n = await a.req('POST', `/friends/${b.id}/call`);
    const m = await b.req('POST', `/nudges/${n.id}/respond`, { action: 'accept' });
    callId = m.callId;
    expect(callId).toBeTruthy();
  });

  it('REF-1..4/10: each reference yields a suggestion of the right photo on the speaker socket only', async () => {
    const sa = await openSocket(a);
    const sb = await openSocket(b);
    try {
      // B speaks first (context from the other speaker), then A references things.
      sb.send({ action: 'transcript', callId, segId: 'b0', text: 'So what did you get up to this week?', startMs: 0, endMs: 1500, clientTs: Date.now() });
      await sleep(500);
      let correct = 0;
      for (const [id, text] of REFERENCES) {
        const t0 = Date.now();
        const before = sa.events.length;
        sa.send({ action: 'transcript', callId, segId: `a-${id}`, text, startMs: 0, endMs: 3000, clientTs: t0 });
        const ev = await sa.waitFor((e) => e.type === 'photo.suggestion' && sa.events.indexOf(e) >= before, 15_000).catch(() => undefined);
        if (ev) {
          latencies.push(Date.now() - t0);
          if (ev.photoId === hash(id)) correct++;
          expect(ev.auto).toBe(false);
          const thumb = await fetch(ev.thumbUrl);
          expect(thumb.ok).toBe(true);
        }
        await sleep(300);
      }
      console.log(`references: ${latencies.length}/${REFERENCES.length} suggested, ${correct} correct; latency ms`, latencies);
      expect(correct).toBeGreaterThanOrEqual(5);
      expect(sb.events.filter((e) => e.type === 'photo.suggestion')).toEqual([]);
    } finally {
      sa.close();
      sb.close();
    }
  });

  it('REF-2: small talk yields no suggestion', async () => {
    const sa = await openSocket(a);
    try {
      sa.send({ action: 'transcript', callId, segId: 'a-small', text: "I'm so tired today, work has been a lot honestly.", startMs: 0, endMs: 2000 });
      await sleep(6000);
      expect(sa.events.filter((e) => e.type === 'photo.suggestion')).toEqual([]);
    } finally {
      sa.close();
    }
  });

  it('REF-5/6: automatic mode flags auto=true; off mode suggests nothing', async () => {
    await a.req('PATCH', '/me', { settings: { photoMode: 'off' } });
    const sa = await openSocket(a);
    try {
      sa.send({ action: 'transcript', callId, segId: 'a-off', text: 'The lasagna I made was the best thing I cooked all month.', startMs: 0, endMs: 2000 });
      await sleep(6000);
      expect(sa.events.filter((e) => e.type === 'photo.suggestion')).toEqual([]);
    } finally {
      sa.close();
    }
    // Re-upload one photo under a new hash so "already suggested" doesn't block auto mode.
    await a.req('PATCH', '/me', { settings: { photoMode: 'auto' } });
    const up = await upload(a, [{ id: 'dog-couch', bytes: img('dog-couch') }]);
    expect(up.uploads.length).toBe(1);
    await until(async () => (await a.req('GET', '/photos/status')).pending === 0, 90_000, 2000);
    const s2 = await openSocket(a);
    try {
      s2.send({ action: 'transcript', callId, segId: 'a-auto', text: 'The puppy fell asleep on the couch right after we got home yesterday.', startMs: 0, endMs: 2000 });
      const ev = await s2.waitFor((e) => e.type === 'photo.suggestion', 15_000);
      expect(ev.auto).toBe(true);
    } finally {
      s2.close();
      await a.req('PATCH', '/me', { settings: { photoMode: 'ask' } });
    }
  });

  it('REF-7/11 + D-6: shares are recipient-only, short-lived, and die with the call', async () => {
    const { shareId, thumbUrl } = await a.req('POST', `/calls/${callId}/shares`, { photoId: hash('lasagna') });
    expect(thumbUrl).toMatch(/^https:/);
    const t0 = Date.now();
    const { url, expiresAt } = await b.req('GET', `/calls/${callId}/shares/${shareId}`);
    const bytes = await fetch(url);
    expect(bytes.ok).toBe(true);
    console.log(`share: fetch URL + download ${Date.now() - t0} ms`);
    expect(Date.parse(expiresAt) - Date.now()).toBeLessThanOrEqual(302_000); // 5 min + clock skew
    await expect(a.req('GET', `/calls/${callId}/shares/${shareId}`)).rejects.toMatchObject({ status: 403 });
    await expect(a.req('POST', `/calls/${callId}/shares`, { photoId: hash('card') })).rejects.toMatchObject({ status: 403 });
    await b.req('POST', `/calls/${callId}/shares/${shareId}/shown`, { shownAt: new Date().toISOString(), durationMs: 6000 });
    await a.req('POST', `/calls/${callId}/end`);
    await expect(b.req('GET', `/calls/${callId}/shares/${shareId}`)).rejects.toBeInstanceOf(ApiError);
  });

  it('REF-10: latency report', () => {
    const s = [...latencies].sort((x, y) => x - y);
    const p = (q: number) => s[Math.min(s.length - 1, Math.floor(q * s.length))];
    console.log(`transcript→suggestion (client-measured, includes WS): p50 ${p(0.5)} ms, p95 ${p(0.95)} ms, n=${s.length}`);
    expect(s.length).toBeGreaterThan(0);
  });
});

describe('photo deletion', () => {
  it('PHO-6: delete all removes items, objects and vectors; PHO-4 sweep runs', async () => {
    await a.req('DELETE', '/photos');
    const s = await a.req('GET', '/photos/status');
    expect(s).toMatchObject({ indexed: 0, excluded: 0, pending: 0 });
    const v = await new S3VectorsClient({ region: 'us-east-1' }).send(
      new GetVectorsCommand({ vectorBucketName: OUTPUTS.VectorBucketName, indexName: 'photos', keys: [`${a.id}#${hash('lasagna')}`] }),
    );
    expect(v.vectors ?? []).toEqual([]);
    const sweep = (await call('POST', '/dev/photos/sweep', a.token)).body;
    expect(sweep).toHaveProperty('vectorsDeleted');
  });
});
