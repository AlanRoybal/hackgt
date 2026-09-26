// ACC-1..12 against the deployed dev stage.
import { createHash } from 'node:crypto';
import { DynamoDBClient, QueryCommand } from '@aws-sdk/client-dynamodb';
import { ListObjectsV2Command, S3Client } from '@aws-sdk/client-s3';
import { afterAll, describe, expect, it } from 'vitest';
import { ApiError, call, cleanup, makeUser, OUTPUTS, until, type TestUser } from './client.js';

const ddb = new DynamoDBClient({ region: 'us-east-1' });
const countPk = async (pk: string) =>
  (await ddb.send(new QueryCommand({ TableName: OUTPUTS.TableName, KeyConditionExpression: 'pk = :p', ExpressionAttributeValues: { ':p': { S: pk } }, Select: 'COUNT' }))).Count ?? 0;
const expectStatus = async (p: Promise<unknown>, status: number, code?: string) => {
  try {
    await p;
    throw new Error('expected failure');
  } catch (e) {
    expect(e).toBeInstanceOf(ApiError);
    expect((e as ApiError).status).toBe(status);
    if (code) expect((e as ApiError).body.error.code).toBe(code);
  }
};

const users: TestUser[] = [];
afterAll(() => cleanup(...users));

describe('accounts', () => {
  it('ACC-1/2: dev sign-in → needsTos/needsHandle, then onboarding clears them', async () => {
    const u = await makeUser('fresh', { onboard: false });
    users.push(u);
    const me = await u.req('GET', '/me');
    expect(me.needsTos).toBe(true);
    expect(me.needsHandle).toBe(true);
    await expectStatus(u.req('POST', '/me/tos', { version: 'old' }), 400, 'tos_version_mismatch');
    const after = await u.req('POST', '/me/tos', { version: me.currentTosVersion });
    expect(after.needsTos).toBe(false);
    expect(after.user.tosAcceptedAt).toBeTruthy();
    expect(after.user.settings.frequency).toBe('normal');
  });

  it('ACC-1: unauthenticated requests are rejected; a bad Apple token is rejected', async () => {
    await expectStatus(call('GET', '/me'), 401);
    await expectStatus(call('POST', '/auth/apple', undefined, { identityToken: 'not.a.jwt' }), 401, 'invalid_token');
  });

  it('ACC-1: refresh returns new tokens', async () => {
    const auth = (await call('POST', '/auth/dev', undefined, { username: `it_refresh_${Date.now()}` })).body;
    const r = (await call('POST', '/auth/refresh', undefined, { refreshToken: auth.refreshToken, userId: auth.userId })).body;
    expect(r.accessToken).toBeTruthy();
    const me = (await call('GET', '/me', r.accessToken)).body;
    expect(me.user.id).toBe(auth.userId);
    await call('DELETE', '/me', r.accessToken);
  });

  it('ACC-3: handle validation, availability, uniqueness', async () => {
    const a = await makeUser('ha');
    const b = await makeUser('hb');
    users.push(a, b);
    expect(await a.req('GET', '/handles/ab')).toEqual({ available: false, reason: 'invalid' });
    expect(await a.req('GET', '/handles/admin')).toEqual({ available: false, reason: 'reserved' });
    expect(await b.req('GET', `/handles/${a.handle}`)).toEqual({ available: false, reason: 'taken' });
    expect(await a.req('GET', `/handles/${a.handle}`)).toEqual({ available: true }); // own handle
    await expectStatus(b.req('PUT', '/me/handle', { handle: a.handle.toUpperCase() }), 409, 'handle_taken');
    // Concurrent claims of one fresh handle: exactly one wins.
    const h = `race_${Date.now().toString(36)}`;
    const results = await Promise.allSettled([a.req('PUT', '/me/handle', { handle: h }), b.req('PUT', '/me/handle', { handle: h })]);
    expect(results.filter((r) => r.status === 'fulfilled').length).toBe(1);
  });

  it('ACC-4: profile name, avatar upload URL, settings validation', async () => {
    const u = await makeUser('prof');
    users.push(u);
    const me = await u.req('PATCH', '/me', { displayName: 'Alan R', settings: { minWindowMin: 15, photoMode: 'auto' } });
    expect(me.user.displayName).toBe('Alan R');
    expect(me.user.settings.minWindowMin).toBe(15);
    await expectStatus(u.req('PATCH', '/me', { settings: { minWindowMin: 7 } }), 400, 'invalid_settings');
    const { uploadUrl, avatarKey } = await u.req('POST', '/me/avatar');
    const put = await fetch(uploadUrl, { method: 'PUT', headers: { 'content-type': 'image/jpeg' }, body: Buffer.from([0xff, 0xd8, 0xff, 0xd9]) });
    expect(put.ok).toBe(true);
    const withAvatar = await u.req('PATCH', '/me', { avatarKey });
    expect(withAvatar.user.avatarUrl).toMatch(/^https:\/\//);
  });

  it('ACC-5/7: phone claim → contact match by hash, and uploaded hashes are not stored', async () => {
    const a = await makeUser('pa');
    const b = await makeUser('pb');
    users.push(a, b);
    const phone = `+1555${String(Date.now()).slice(-7)}`;
    const me = await call('POST', '/dev/phone/verify', a.token, { userId: a.id, phone });
    expect(me.body.user.phoneVerified).toBe(true);
    const hash = createHash('sha256').update(phone).digest('hex');
    const decoy = createHash('sha256').update('+15550000000').digest('hex');
    const before = await countPk(`PHONE#${decoy}`);
    const r = await b.req('POST', '/contacts/match', { hashes: [hash, decoy] });
    expect(r.results.map((x: any) => x.id)).toEqual([a.id]);
    expect(r.results[0].relation).toBe('none');
    expect(await countPk(`PHONE#${decoy}`)).toBe(before);
  });

  it('ACC-6/9: search, request, mutual accept, auto-accept on crossed requests, decline and cancel', async () => {
    const a = await makeUser('fa');
    const b = await makeUser('fb');
    const c = await makeUser('fc');
    users.push(a, b, c);
    const hit = await until(async () => (await a.req('GET', `/users/search?q=${b.handle}`)).results.find((x: any) => x.id === b.id));
    expect(hit.relation).toBe('none');
    expect((await a.req('POST', '/friend-requests', { handle: b.handle })).relation).toBe('requested');
    expect((await b.req('GET', '/friend-requests')).incoming[0].user.id).toBe(a.id);
    // Outgoing requests come from a GSI (eventually consistent).
    expect((await until(async () => (await a.req('GET', '/friend-requests')).outgoing[0])).user.id).toBe(b.id);
    expect((await b.req('POST', `/friend-requests/${a.id}/accept`)).relation).toBe('friends');
    expect((await a.req('GET', '/friends')).friends.map((f: any) => f.user.id)).toEqual([b.id]);
    expect((await b.req('GET', '/friends')).friends.map((f: any) => f.user.id)).toEqual([a.id]);
    // Crossed requests: c → a, then a → c auto-accepts.
    await c.req('POST', '/friend-requests', { userId: a.id });
    expect((await a.req('POST', '/friend-requests', { userId: c.id })).relation).toBe('friends');
    // Decline and cancel.
    await b.req('POST', '/friend-requests', { userId: c.id });
    await c.req('POST', `/friend-requests/${b.id}/decline`);
    expect((await c.req('GET', '/friend-requests')).incoming).toEqual([]);
    await b.req('POST', '/friend-requests', { userId: c.id });
    await b.req('DELETE', `/friend-requests/${c.id}`);
    expect((await c.req('GET', '/friend-requests')).incoming).toEqual([]);
  });

  it('ACC-10/11: nicknames are private; remove and block', async () => {
    const a = await makeUser('na');
    const b = await makeUser('nb');
    users.push(a, b);
    await a.req('POST', '/friend-requests', { userId: b.id });
    await b.req('POST', `/friend-requests/${a.id}/accept`);
    const f = await a.req('PATCH', `/friends/${b.id}`, { nickname: 'Mom' });
    expect(f.nickname).toBe('Mom');
    expect((await b.req('GET', '/friends')).friends[0].nickname).toBeUndefined();
    await a.req('POST', `/blocks/${b.id}`);
    expect((await a.req('GET', '/friends')).friends).toEqual([]);
    expect((await b.req('GET', '/friends')).friends).toEqual([]);
    expect((await b.req('GET', `/users/search?q=${a.handle}`)).results).toEqual([]);
    await expectStatus(b.req('POST', '/friend-requests', { userId: a.id }), 404);
    expect((await a.req('GET', '/blocks')).users.map((u: any) => u.id)).toEqual([b.id]);
    await a.req('DELETE', `/blocks/${b.id}`);
    expect((await a.req('POST', '/friend-requests', { userId: b.id })).relation).toBe('requested');
  });

  it('WebSocket: bad tokens are rejected at $connect; ping → pong', async () => {
    const u = await makeUser('ws');
    users.push(u);
    const { WS } = await import('./client.js');
    const WebSocket = (await import('ws')).default;
    const status = await new Promise<number>((resolve) => {
      const bad = new WebSocket(`${WS}?token=nope`);
      bad.once('unexpected-response', (_q, res) => resolve(res.statusCode ?? 0));
      bad.once('open', () => resolve(101));
    });
    expect(status).toBe(401);
    const { openSocket } = await import('./client.js');
    const s = await openSocket(u);
    s.send({ action: 'ping' });
    expect(await s.waitFor((e) => e.type === 'pong', 10_000)).toEqual({ type: 'pong' });
    s.close();
  });

  it('ACC-12: delete account removes items, claims, S3 objects and the Cognito user', async () => {
    const a = await makeUser('del');
    const b = await makeUser('delf');
    users.push(b);
    await a.req('POST', '/friend-requests', { userId: b.id });
    await b.req('POST', `/friend-requests/${a.id}/accept`);
    await a.req('POST', `/friends/${b.id}/messages`, { body: 'hi' });
    const { uploadUrl, avatarKey } = await a.req('POST', '/me/avatar');
    await fetch(uploadUrl, { method: 'PUT', headers: { 'content-type': 'image/jpeg' }, body: Buffer.from([1, 2, 3]) });
    await a.req('PATCH', '/me', { avatarKey });
    const r = await call('DELETE', '/me', a.token);
    expect(r.status).toBe(202);
    expect(await countPk(`USER#${a.id}`)).toBe(0);
    expect(await countPk(`HANDLE#${a.handle}`)).toBe(0);
    expect(await countPk(`PAIR#${[a.id, b.id].sort().join('_')}`)).toBe(0);
    expect((await b.req('GET', '/friends')).friends).toEqual([]);
    const objs = await new S3Client({ region: 'us-east-1' }).send(new ListObjectsV2Command({ Bucket: OUTPUTS.MediaBucket, Prefix: `avatars/${a.id}` }));
    expect(objs.KeyCount ?? 0).toBe(0);
    await expectStatus(call('POST', '/auth/refresh', undefined, { refreshToken: 'x' }), 401);
  });
});
