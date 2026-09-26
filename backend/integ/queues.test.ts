// Real SQS delay paths (no dev shortcuts): 60 s pre-check, 180 s expiry → follow-up, 30 s summarize. Takes ~5 min.
import { afterAll, describe, expect, it } from 'vitest';
import { befriend, call, cleanup, makeUser, openSocket, sleep, until, type TestUser } from './client.js';

const users: TestUser[] = [];
afterAll(() => cleanup(...users));

describe('queued delays', { timeout: 420_000 }, () => {
  it('NUD-4/10: pre-check fires after ~60 s, expiry after ~180 s sends the follow-up', async () => {
    const a = await makeUser('qa');
    const b = await makeUser('qb');
    users.push(a, b);
    await befriend(a, b);
    const r = await until(async () => {
      const res = (await call('POST', '/dev/matcher/run', a.token, { onlyUserIds: [a.id, b.id], immediate: false })).body;
      return res.created.length ? res : undefined;
    });
    const id = r.created[0];
    const t0 = Date.now();
    expect((await a.req('GET', `/nudges/${id}`)).state).toBe('precheck');
    await until(async () => (await a.req('GET', `/nudges/${id}`)).state === 'pending', 150_000, 3000);
    const precheckSec = (Date.now() - t0) / 1000;
    console.log(`pre-check delivered after ${precheckSec.toFixed(0)} s`);
    expect(precheckSec).toBeGreaterThanOrEqual(50);
    await a.req('POST', `/nudges/${id}/respond`, { action: 'accept' });
    const t1 = Date.now();
    await until(async () => (await a.req('GET', `/nudges/${id}`)).state === 'expired', 260_000, 5000);
    console.log(`expired after ${((Date.now() - t1) / 1000).toFixed(0)} s from accept`);
    const msgs = await until(async () => {
      const m = (await a.req('GET', `/friends/${b.id}/messages`)).messages;
      return m.some((x: any) => x.kind === 'auto_followup') ? m : undefined;
    });
    expect(msgs.find((m: any) => m.kind === 'auto_followup').senderId).toBe(b.id);
  });

  it('MEM-2: the summarize queue produces the summary without the dev hook', async () => {
    const a = await makeUser('qsa');
    const b = await makeUser('qsb');
    users.push(a, b);
    await befriend(a, b);
    for (const u of [a, b]) await u.req('PATCH', '/me', { settings: { photoMode: 'off' } });
    const n = await a.req('POST', `/friends/${b.id}/call`);
    const m = await b.req('POST', `/nudges/${n.id}/respond`, { action: 'accept' });
    const s = await openSocket(a);
    s.send({ action: 'transcript', callId: m.callId, segId: 'q1', text: 'My driving test is next Wednesday and I am so nervous about parallel parking.', startMs: 0, endMs: 2000 });
    await sleep(1500);
    await b.req('POST', `/calls/${m.callId}/end`);
    const ready = await s.waitFor((e) => e.type === 'call.summary.ready', 120_000);
    s.close();
    expect(ready.callId).toBe(m.callId);
    const summary = await a.req('GET', `/calls/${m.callId}/summary`);
    expect(summary.topics.length).toBeGreaterThanOrEqual(1);
  });
});
