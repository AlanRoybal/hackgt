// NUD-1..13 + MSG against the deployed dev stage.
import { afterAll, describe, expect, it } from 'vitest';
import { befriend, call, cleanup, makeUser, openSocket, until, type TestUser } from './client.js';

const users: TestUser[] = [];
afterAll(() => cleanup(...users));

async function pair(label: string) {
  const a = await makeUser(`${label}a`);
  const b = await makeUser(`${label}b`);
  users.push(a, b);
  await befriend(a, b);
  return [a, b] as const;
}

/** Runs the matcher (inline pre-check) for just these users until it creates a nudge. */
async function matchNudge(a: TestUser, b: TestUser) {
  const r = await until(async () => {
    const res = (await call('POST', '/dev/matcher/run', a.token, { onlyUserIds: [a.id, b.id], immediate: true })).body;
    return res.created.length ? res : undefined;
  }, 20_000, 1000);
  return r.created[0] as string;
}

const pushes = async (u: TestUser) => (await call('GET', `/dev/pushes/${u.id}`, u.token)).body.pushes as any[];

describe('nudges', () => {
  it('NUD-1/7/8: matcher nudges a free pair with each viewer\'s own nickname; alert push has category NUDGE', async () => {
    const [a, b] = await pair('m');
    await a.req('PATCH', `/friends/${b.id}`, { nickname: 'Mom' });
    await a.req('PUT', '/me/availability', {
      busyBlocks: [{ start: new Date(Date.now() + 22 * 60_000).toISOString(), end: new Date(Date.now() + 90 * 60_000).toISOString() }],
      syncedAt: new Date().toISOString(),
      source: 'apple',
      tz: 'UTC',
    });
    const id = await matchNudge(a, b);
    const na = await a.req('GET', `/nudges/${id}`);
    expect(na.state).toBe('pending');
    expect(na.body).toBe('You and Mom are both free for the next 20 minutes. Call?');
    expect(na.nickname).toBe('Mom');
    const nb = await b.req('GET', '/nudges/active');
    expect(nb.nudge.id).toBe(id);
    expect(nb.nudge.body).toMatch(/^You and .+ are both free for the next 20 minutes\. Call\?$/);
    const pa = await pushes(a);
    expect(pa.some((p) => p.kind === 'background' && p.payload.type === 'availability.check')).toBe(true);
    const alert = pa.find((p) => p.kind === 'alert' && p.payload.type === 'nudge');
    expect(alert.payload.aps.category).toBe('NUDGE');
    expect(alert.payload.nudgeId).toBe(id);
    expect(alert.payload.friendName).toBe('Mom');
  });

  it('NUD-11: both accept → matched call; waiting-room user gets WS call.matched, the other gets a VoIP push', async () => {
    const [a, b] = await pair('acc');
    const id = await matchNudge(a, b);
    const sa = await openSocket(a);
    try {
      await a.req('POST', `/nudges/${id}/respond`, { action: 'accept' });
      sa.send({ action: 'waiting', nudgeId: id });
      await sa.waitFor((e) => e.type === 'nudge.updated' && e.nudge.state === 'accepted_by_one');
      await new Promise((r) => setTimeout(r, 800)); // let the waiting route land
      const n = await b.req('POST', `/nudges/${id}/respond`, { action: 'accept' });
      expect(n.state).toBe('matched');
      expect(n.callId).toBeTruthy();
      const matched = await sa.waitFor((e) => e.type === 'call.matched');
      expect(matched.callId).toBe(n.callId);
      const voip = (await pushes(b)).find((p) => p.kind === 'voip');
      expect(voip.payload).toMatchObject({ type: 'call.incoming', callId: n.callId, callerId: a.id, hasVideo: true });
      expect((await pushes(a)).find((p) => p.kind === 'voip')).toBeUndefined();
      const join = await b.req('GET', `/calls/${n.callId}/join`);
      expect(join.meeting.MeetingId).toBeTruthy();
      expect(join.attendee.ExternalUserId).toBe(b.id);
      expect(join.peerAttendeeId).toBeTruthy();
      expect((await a.req('GET', `/nudges/${id}`)).state).toBe('in_call');
      await a.req('POST', `/calls/${n.callId}/end`);
      const thread = await a.req('GET', `/friends/${b.id}/messages`);
      expect(thread.messages[0].kind).toBe('system');
      expect(thread.messages[0].body).toMatch(/^Called · \d+ min$/);
      expect((await a.req('GET', '/nudges/active')).nudge).toBeNull();
    } finally {
      sa.close();
    }
  });

  it('NUD-12: one accepts, the other skips → auto follow-up message from the skipper + push to the accepter', async () => {
    const [a, b] = await pair('skip');
    const id = await matchNudge(a, b);
    await a.req('POST', `/nudges/${id}/respond`, { action: 'accept' });
    const n = await b.req('POST', `/nudges/${id}/respond`, { action: 'skip' });
    expect(n.state).toBe('skipped');
    const msgs = await until(async () => {
      const m = (await a.req('GET', `/friends/${b.id}/messages`)).messages;
      return m.some((x: any) => x.kind === 'auto_followup') ? m : undefined;
    });
    const auto = msgs.find((m: any) => m.kind === 'auto_followup');
    expect(auto.senderId).toBe(b.id);
    expect(auto.body.length).toBeGreaterThan(5);
    expect(msgs.some((m: any) => m.kind === 'system' && m.body === 'Missed nudge')).toBe(true);
    expect((await pushes(a)).some((p) => p.kind === 'alert' && p.payload.type === 'message.new')).toBe(true);
    expect((await pushes(a)).some((p) => p.kind === 'background' && p.payload.type === 'nudge.cleanup')).toBe(true);
    const conv = await a.req('GET', '/conversations');
    expect(conv.conversations[0].unread).toBeGreaterThanOrEqual(1);
    await a.req('POST', `/friends/${b.id}/messages/read`);
    expect((await a.req('GET', '/conversations')).conversations[0].unread).toBe(0);
  });

  it('NUD-12: skipBehavior=nothing sends no follow-up; expiry counts as a skip', async () => {
    const [a, b] = await pair('exp');
    await b.req('PATCH', '/me', { settings: { skipBehavior: 'nothing' } });
    const id = await matchNudge(a, b);
    await a.req('POST', `/nudges/${id}/respond`, { action: 'accept' });
    const r = (await call('POST', `/dev/nudges/${id}/expire`, a.token)).body;
    expect(r.state).toBe('expired');
    const n = await a.req('GET', `/nudges/${id}`);
    expect(n.theirResponse).toBe('expired');
    const msgs = (await a.req('GET', `/friends/${b.id}/messages`)).messages;
    expect(msgs.some((m: any) => m.kind === 'auto_followup')).toBe(false);
    // With the default (message), expiry sends one.
    await b.req('PATCH', '/me', { settings: { skipBehavior: 'message', frequency: 'high' } });
  });

  it('NUD-5: "less" skips and steps frequency down; undo restores it', async () => {
    const [a, b] = await pair('less');
    const id = await matchNudge(a, b);
    const n = await b.req('POST', `/nudges/${id}/respond`, { action: 'less' });
    expect(n.state).toBe('skipped');
    expect((await b.req('GET', '/me')).user.settings.frequency).toBe('normal'); // high → normal
    expect((await b.req('POST', '/me/frequency/undo')).user.settings.frequency).toBe('high');
    expect((await b.req('POST', '/me/frequency/less')).user.settings.frequency).toBe('normal');
  });

  it('NUD-2/5: suppression — focus, busy calendar, pair cooldown after a nudge', async () => {
    const [a, b] = await pair('sup');
    await b.req('PUT', '/me/context', { focus: { isFocused: true, at: new Date().toISOString() } });
    let r = (await call('POST', '/dev/matcher/run', a.token, { onlyUserIds: [a.id, b.id] })).body;
    await until(async () => {
      r = (await call('POST', '/dev/matcher/run', a.token, { onlyUserIds: [a.id, b.id] })).body;
      return r.considered === 1 ? r : undefined;
    });
    expect(r.created).toEqual([]);
    expect(Object.values(r.skipped)[0]).toContain('b:focus');
    await b.req('PUT', '/me/context', { focus: { isFocused: false, at: new Date().toISOString() } });
    await b.req('PUT', '/me/availability', {
      busyBlocks: [{ start: new Date(Date.now() - 60_000).toISOString(), end: new Date(Date.now() + 3_600_000).toISOString() }],
      syncedAt: new Date().toISOString(),
      source: 'apple',
      tz: 'UTC',
    });
    r = (await call('POST', '/dev/matcher/run', a.token, { onlyUserIds: [a.id, b.id] })).body;
    expect(Object.values(r.skipped)[0]).toContain('busy_now');
    await b.req('PUT', '/me/availability', { busyBlocks: [], syncedAt: new Date().toISOString(), source: 'apple', tz: 'UTC' });
    const id = await matchNudge(a, b);
    await a.req('POST', `/nudges/${id}/respond`, { action: 'skip' });
    r = (await call('POST', '/dev/matcher/run', a.token, { onlyUserIds: [a.id, b.id] })).body;
    expect(r.created).toEqual([]);
    expect(Object.values(r.skipped)[0]).toEqual(expect.arrayContaining(['pair_cooldown']));
  });

  it('NUD-13: Call now creates a direct nudge with the caller pre-accepted', async () => {
    const [a, b] = await pair('dir');
    const n = await a.req('POST', `/friends/${b.id}/call`);
    expect(n.kind).toBe('direct');
    expect(n.state).toBe('accepted_by_one');
    expect(n.myResponse).toBe('accepted');
    const nb = await b.req('GET', `/nudges/${n.id}`);
    expect(nb.body).toMatch(/wants to call\. Free\?$/);
    const matched = await b.req('POST', `/nudges/${n.id}/respond`, { action: 'accept' });
    expect(matched.state).toBe('matched');
    await b.req('POST', `/calls/${matched.callId}/end`);
    // Cancel from the waiting room.
    const n2 = await a.req('POST', `/friends/${b.id}/call`);
    expect((await a.req('POST', `/nudges/${n2.id}/cancel`)).state).toBe('cancelled');
  });
});
