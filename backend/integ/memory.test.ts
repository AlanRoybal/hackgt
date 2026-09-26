// MEM-1..5 and CALL-5 against the deployed dev stage.
import { DynamoDBClient, QueryCommand } from '@aws-sdk/client-dynamodb';
import { afterAll, describe, expect, it } from 'vitest';
import { befriend, call, cleanup, makeUser, OUTPUTS, openSocket, sleep, until, type TestUser } from './client.js';

const ddb = new DynamoDBClient({ region: 'us-east-1' });
const segCount = async (callId: string) =>
  (
    await ddb.send(
      new QueryCommand({
        TableName: OUTPUTS.TableName,
        KeyConditionExpression: 'pk = :p AND begins_with(sk, :s)',
        ExpressionAttributeValues: { ':p': { S: `CALL#${callId}` }, ':s': { S: 'SEG#' } },
        Select: 'COUNT',
      }),
    )
  ).Count ?? 0;

const users: TestUser[] = [];
afterAll(() => cleanup(...users));

async function startCall(a: TestUser, b: TestUser) {
  const n = await a.req('POST', `/friends/${b.id}/call`);
  const m = await b.req('POST', `/nudges/${n.id}/respond`, { action: 'accept' });
  return m.callId as string;
}

async function talk(u: TestUser, callId: string, lines: string[]) {
  const s = await openSocket(u);
  for (const [i, text] of lines.entries()) {
    s.send({ action: 'transcript', callId, segId: `${u.id.slice(0, 6)}-${i}-${Date.now()}`, text, startMs: i * 1000, endMs: i * 1000 + 900 });
    await sleep(250);
  }
  await sleep(1500);
  s.close();
}

describe('memory', () => {
  it('MEM-1/2/3 + CALL-5: summary and topics after the call; transcript deleted; the other side gets call.ended', async () => {
    const a = await makeUser('mema');
    const b = await makeUser('memb');
    users.push(a, b);
    await befriend(a, b);
    await a.req('PATCH', '/me', { settings: { photoMode: 'off' } });
    await b.req('PATCH', '/me', { settings: { photoMode: 'off' } });
    const callId = await startCall(a, b);
    await talk(b, callId, ["How's school going?"]);
    await talk(a, callId, [
      "Honestly stressful, I have my physics exam on Thursday and I'm not ready.",
      'After that I fly to Denver for my cousin\'s wedding next weekend.',
    ]);
    expect(await segCount(callId)).toBe(3);
    const sb = await openSocket(b);
    await a.req('POST', `/calls/${callId}/end`);
    const ended = await sb.waitFor((e) => e.type === 'call.ended');
    expect(ended.callId).toBe(callId);
    sb.close();
    const pending = await call('GET', `/calls/${callId}/summary`, a.token);
    expect(pending.status).toBe(202);
    const r = (await call('POST', `/dev/calls/${callId}/summarize`, a.token)).body;
    expect(r.allowed).toBe(true);
    expect(r.topicsCreated).toBeGreaterThanOrEqual(1);
    expect(await segCount(callId)).toBe(0);
    const s = await b.req('GET', `/calls/${callId}/summary`);
    expect(s.summary.length).toBeGreaterThan(10);
    // Names, not the transcript's A/B labels.
    expect(s.summary).not.toMatch(/\b(A and B|B and A)\b/);
    expect(s.summary).toMatch(/mema|memb/i);
    const exam = s.topics.find((t: any) => /physics|exam/i.test(t.title));
    expect(exam).toBeTruthy();
    expect(exam.aboutUserId).toBe(a.id);
    // A full ISO timestamp: the iOS decoder rejects a bare day and would drop the whole payload.
    expect(exam.followUpAfter).toMatch(/^\d{4}-\d{2}-\d{2}T00:00:00\.000Z$/);
    // Both see memories; either can delete, and it's gone for both.
    const ma = await a.req('GET', `/friends/${b.id}/memories`);
    const mb = await b.req('GET', `/friends/${a.id}/memories`);
    expect(ma.topics.length).toBe(mb.topics.length);
    expect(mb.summaries[0].callId).toBe(callId);
    expect(mb.topics.every((t: any) => !t.followUpAfter || t.followUpAfter.endsWith('T00:00:00.000Z'))).toBe(true);
    await b.req('DELETE', `/friends/${a.id}/topics/${exam.id}`);
    expect((await a.req('GET', `/friends/${b.id}/memories`)).topics.find((t: any) => t.id === exam.id)).toBeUndefined();
    await a.req('DELETE', `/friends/${b.id}/summaries/${callId}`);
    expect((await b.req('GET', `/friends/${a.id}/memories`)).summaries).toEqual([]);
  });

  it('MEM-4: if either person has memory off, nothing is stored but the transcript is still deleted', async () => {
    const a = await makeUser('mofa');
    const b = await makeUser('mofb');
    users.push(a, b);
    await befriend(a, b);
    await b.req('PATCH', '/me', { settings: { memoryEnabled: false, photoMode: 'off' } });
    await a.req('PATCH', '/me', { settings: { photoMode: 'off' } });
    const callId = await startCall(a, b);
    const join = await a.req('GET', `/calls/${callId}/join`);
    expect(join.memoryAllowed).toBe(false);
    await talk(a, callId, ['I have a job interview at Google on Monday, wish me luck.']);
    await a.req('POST', `/calls/${callId}/end`);
    const r = (await call('POST', `/dev/calls/${callId}/summarize`, a.token)).body;
    expect(r.allowed).toBe(false);
    expect(await segCount(callId)).toBe(0);
    expect((await a.req('GET', `/friends/${b.id}/memories`)).topics).toEqual([]);
    const s = await a.req('GET', `/calls/${callId}/summary`);
    expect(s.topics).toEqual([]);
  });

  it('MEM-5: a due topic is preferred and appears in the nudge copy, then becomes "used" after a call', async () => {
    const a = await makeUser('fua');
    const b = await makeUser('fub');
    users.push(a, b);
    await befriend(a, b);
    await a.req('PATCH', `/friends/${b.id}`, { nickname: 'Mom' });
    for (const u of [a, b]) await u.req('PATCH', '/me', { settings: { photoMode: 'off' } });
    const callId = await startCall(a, b);
    await talk(b, callId, ['My physics exam was yesterday and I think it went okay but results come out Friday.']);
    await a.req('POST', `/calls/${callId}/end`);
    await call('POST', `/dev/calls/${callId}/summarize`, a.token);
    const topics = (await a.req('GET', `/friends/${b.id}/memories`)).topics;
    expect(topics.length).toBeGreaterThanOrEqual(1);
    // Make one topic due now by matching after its followUpAfter date, and bypass the post-call pair cooldown.
    const topic = topics[0];
    const matchAt = new Date(Date.parse(`${topic.followUpAfter.slice(0, 10)}T12:00:00Z`) + 86_400_000 * 4).toISOString();
    for (const u of [a, b]) {
      await u.req('PUT', '/me/availability', { busyBlocks: [], syncedAt: matchAt, source: 'apple', tz: 'UTC' });
    }
    const r = await until(async () => {
      const res = (await call('POST', '/dev/matcher/run', a.token, { onlyUserIds: [a.id, b.id], now: matchAt, immediate: true })).body;
      return res.created.length ? res : undefined;
    });
    const n = await a.req('GET', `/nudges/${r.created[0]}`);
    expect(n.topic?.id).toBeDefined();
    expect(n.body).toMatch(/^You and Mom are both free for .+\. Want to follow up on .+\?$/);
    // Accept both → call → end → the suggested topic becomes used.
    await a.req('POST', `/nudges/${n.id}/respond`, { action: 'accept' });
    const m = await b.req('POST', `/nudges/${n.id}/respond`, { action: 'accept' });
    // Accepting the nudge is enough to mark its topic used.
    expect((await a.req('GET', `/friends/${b.id}/memories`)).topics.find((t: any) => t.id === n.topic.id).status).toBe('used');
    await a.req('POST', `/calls/${m.callId}/end`);
    const after = (await a.req('GET', `/friends/${b.id}/memories`)).topics.find((t: any) => t.id === n.topic.id);
    expect(after.status).toBe('used');
    // Dismiss works.
    const other = topics.find((t: any) => t.id !== n.topic.id);
    if (other) {
      await b.req('POST', `/friends/${a.id}/topics/${other.id}/dismiss`);
      expect((await a.req('GET', `/friends/${b.id}/memories`)).topics.find((t: any) => t.id === other.id).status).toBe('dismissed');
    }
  });
});
