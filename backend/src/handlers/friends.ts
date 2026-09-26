// Friends, requests, blocks, contacts, memories, call history, "Call now".
import { checkHandle, normalizeHandle } from '../engine/handles.js';
import { freeStatus } from '../engine/overlap.js';
import { isStale } from '../engine/suppression.js';
import { batchDelete, batchGet, del, get, put, queryGsi, queryPartition, queryPrefix, update } from '../lib/db.js';
import { createDirectNudge, nudgeDTO, topicDTO } from '../lib/flows.js';
import { bad, forbidden, notFound, router } from '../lib/http.js';
import { K, pairKey } from '../lib/keys.js';
import { payloads, pushToUser } from '../lib/push.js';
import {
  getFriendship,
  getUser,
  loadAvailability,
  loadUsers,
  nameFor,
  publicUser,
  type FriendshipItem,
  type UserItem,
} from '../lib/users.js';
import { sendToUser } from '../lib/ws.js';

type Relation = 'none' | 'requested' | 'incoming' | 'friends' | 'blocked';

async function isBlockedEitherWay(a: string, b: string) {
  const [x, y] = await Promise.all([get(K.block(a, b)), get(K.block(b, a))]);
  return !!(x || y);
}

async function relation(me: string, other: string): Promise<Relation> {
  const [fs, out, inc, blocked] = await Promise.all([
    getFriendship(me, other),
    get(K.freq(other, me)),
    get(K.freq(me, other)),
    isBlockedEitherWay(me, other),
  ]);
  if (blocked) return 'blocked';
  if (fs) return 'friends';
  if (out) return 'requested';
  if (inc) return 'incoming';
  return 'none';
}

async function searchResults(me: string, users: UserItem[]) {
  const out = [];
  for (const u of users) {
    if (u.id === me || !u.handle) continue;
    const rel = await relation(me, u.id);
    if (rel === 'blocked') continue;
    out.push({ ...(await publicUser(u)), relation: rel });
  }
  return out;
}

async function makeFriends(a: string, b: string) {
  const since = new Date().toISOString();
  const pk = pairKey(a, b);
  for (const [x, y] of [
    [a, b],
    [b, a],
  ]) {
    const existing = await getFriendship(x, y);
    await put({
      ...K.friend(x, y),
      a: x,
      b: y,
      pairKey: pk,
      since: existing?.since ?? since,
      nickname: existing?.nickname,
      lastCallAt: existing?.lastCallAt,
      lastNudgeAt: existing?.lastNudgeAt,
      gsi1pk: 'FRIENDSHIPS',
      gsi1sk: `${pk}#${x}`,
    });
  }
  await batchDelete([K.freq(a, b), K.freq(b, a)]);
}

async function friendDTO(me: string, fs: FriendshipItem, users: Map<string, UserItem>, avail: Map<string, any>, now: number) {
  const u = users.get(fs.b)!;
  const a = avail.get(fs.b);
  const status = a && !isStale(a, now) ? freeStatus(now, a.busyBlocks ?? []) : { freeNow: false };
  return {
    user: await publicUser(u),
    nickname: fs.nickname,
    since: fs.since,
    lastCallAt: fs.lastCallAt,
    freeNow: status.freeNow,
    freeUntil: status.freeUntil,
  };
}

async function requireFriend(me: string, other: string) {
  const fs = await getFriendship(me, other);
  if (!fs) throw forbidden('not_friends');
  return fs;
}

async function topicDTOs(pk: string) {
  const topics = await queryPrefix(`PAIR#${pk}`, 'TOPIC#');
  return topics.map(topicDTO);
}

export const handler = router({
  'GET /users/search': async ({ userId, query }) => {
    const q = normalizeHandle(query.q ?? '');
    if (!q) return { results: [] };
    const users = await queryGsi<UserItem>('USERS', q, { limit: 25 });
    return { results: (await searchResults(userId, users)).slice(0, 20) };
  },

  'POST /contacts/match': async ({ userId, body }) => {
    if (!Array.isArray(body.hashes) || body.hashes.length > 2000) throw bad('invalid_hashes');
    const hashes = [...new Set(body.hashes.filter((h: unknown) => typeof h === 'string' && /^[0-9a-f]{64}$/i.test(h as string)))] as string[];
    // Hashes are only used for this lookup and never stored (ACC-7).
    const claims = await batchGet(hashes.map((h) => K.phone(h.toLowerCase())));
    const users = await loadUsers([...new Set(claims.map((c) => c.userId as string))]);
    return { results: await searchResults(userId, [...users.values()]) };
  },

  'GET /friends': async ({ userId }) => {
    const fss = await queryPrefix<FriendshipItem>(`USER#${userId}`, 'FRIEND#');
    const ids = fss.map((f) => f.b);
    const [users, avail] = await Promise.all([loadUsers(ids), loadAvailability(ids)]);
    const now = Date.now();
    const friends = await Promise.all(fss.filter((f) => users.has(f.b)).map((f) => friendDTO(userId, f, users, avail, now)));
    return { friends };
  },

  'GET /friend-requests': async ({ userId }) => {
    const incoming = await queryPrefix(`USER#${userId}`, 'FREQ#');
    const outgoing = await queryGsi(`FREQOUT#${userId}`);
    const users = await loadUsers([...incoming.map((r) => r.from), ...outgoing.map((r) => r.to)]);
    const dto = async (id: string, createdAt: string) => (users.get(id) ? { user: await publicUser(users.get(id)!), createdAt } : null);
    return {
      incoming: (await Promise.all(incoming.map((r) => dto(r.from, r.createdAt)))).filter(Boolean),
      outgoing: (await Promise.all(outgoing.map((r) => dto(r.to, r.createdAt)))).filter(Boolean),
    };
  },

  'POST /friend-requests': async ({ userId, body }) => {
    let targetId: string | undefined = typeof body.userId === 'string' ? body.userId : undefined;
    if (!targetId && typeof body.handle === 'string') {
      const c = checkHandle(body.handle);
      if (!c.ok) throw notFound('user_not_found');
      targetId = (await get(K.handle(c.handle)))?.userId;
    }
    if (!targetId || targetId === userId) throw notFound('user_not_found');
    const target = await getUser(targetId);
    const rel = await relation(userId, targetId);
    if (rel === 'blocked') throw notFound('user_not_found');
    if (rel === 'friends' || rel === 'requested') return { relation: rel };
    const me = await getUser(userId);
    if (rel === 'incoming') {
      await makeFriends(userId, targetId);
      await sendToUser(targetId, { type: 'friend.accepted', user: await publicUser(me) });
      await pushToUser(targetId, 'alert', payloads.alert('friend.accepted', 'Nudge', `${nameFor(me)} accepted your request`, { userId }));
      return { relation: 'friends' };
    }
    const createdAt = new Date().toISOString();
    await put({ ...K.freq(targetId, userId), from: userId, to: targetId, createdAt, gsi1pk: `FREQOUT#${userId}`, gsi1sk: targetId });
    await sendToUser(targetId, { type: 'friend.request', user: await publicUser(me) });
    await pushToUser(targetId, 'alert', payloads.alert('friend.request', 'Nudge', `${nameFor(me)} wants to be friends`, { userId }));
    void target;
    return { relation: 'requested' };
  },

  'POST /friend-requests/{userId}/accept': async ({ userId, params }) => {
    const from = params.userId;
    const req = await get(K.freq(userId, from));
    if (!req) throw notFound('request_not_found');
    await makeFriends(userId, from);
    const me = await getUser(userId);
    await sendToUser(from, { type: 'friend.accepted', user: await publicUser(me) });
    await pushToUser(from, 'alert', payloads.alert('friend.accepted', 'Nudge', `${nameFor(me)} accepted your request`, { userId }));
    return { relation: 'friends' };
  },

  'POST /friend-requests/{userId}/decline': async ({ userId, params }) => {
    await del(K.freq(userId, params.userId));
  },

  'DELETE /friend-requests/{userId}': async ({ userId, params }) => {
    await del(K.freq(params.userId, userId));
  },

  'PATCH /friends/{userId}': async ({ userId, params, body }) => {
    const fs = await requireFriend(userId, params.userId);
    const nick = body.nickname;
    if (nick !== null && (typeof nick !== 'string' || nick.length > 40)) throw bad('invalid_nickname');
    const updated = (await update(K.friend(userId, params.userId), { nickname: nick?.trim() || undefined })) as FriendshipItem;
    const users = await loadUsers([fs.b]);
    const avail = await loadAvailability([fs.b]);
    return friendDTO(userId, updated, users, avail, Date.now());
  },

  'DELETE /friends/{userId}': async ({ userId, params }) => {
    await batchDelete([K.friend(userId, params.userId), K.friend(params.userId, userId)]);
  },

  'GET /blocks': async ({ userId }) => {
    const blocks = await queryPrefix(`USER#${userId}`, 'BLOCK#');
    const users = await loadUsers(blocks.map((b) => b.sk.slice('BLOCK#'.length)));
    return { users: await Promise.all([...users.values()].map(publicUser)) };
  },

  'POST /blocks/{userId}': async ({ userId, params }) => {
    const other = params.userId;
    if (other === userId) throw bad('cannot_block_self');
    await put({ ...K.block(userId, other), createdAt: new Date().toISOString() });
    await batchDelete([K.friend(userId, other), K.friend(other, userId), K.freq(userId, other), K.freq(other, userId)]);
  },

  'DELETE /blocks/{userId}': async ({ userId, params }) => {
    await del(K.block(userId, params.userId));
  },

  'GET /friends/{userId}/memories': async ({ userId, params }) => {
    await requireFriend(userId, params.userId);
    const pk = pairKey(userId, params.userId);
    const topics = await topicDTOs(pk);
    const summaries = await queryPrefix(`PAIR#${pk}`, 'SUMMARY#', { desc: true });
    return {
      topics,
      summaries: summaries.map((s) => ({
        callId: s.callId,
        summary: s.summary,
        durationSec: s.durationSec,
        createdAt: s.createdAt,
        topics: topics.filter((t) => t.sourceCallId === s.callId),
      })),
    };
  },

  'DELETE /friends/{userId}/topics/{topicId}': async ({ userId, params }) => {
    await requireFriend(userId, params.userId);
    await del(K.topic(pairKey(userId, params.userId), params.topicId));
  },

  'POST /friends/{userId}/topics/{topicId}/dismiss': async ({ userId, params }) => {
    await requireFriend(userId, params.userId);
    const key = K.topic(pairKey(userId, params.userId), params.topicId);
    if (!(await get(key))) throw notFound('topic_not_found');
    await update(key, { status: 'dismissed' });
  },

  'DELETE /friends/{userId}/summaries/{callId}': async ({ userId, params }) => {
    await requireFriend(userId, params.userId);
    await del(K.summary(pairKey(userId, params.userId), params.callId));
  },

  'DELETE /memories': async ({ userId }) => {
    const fss = await queryPrefix<FriendshipItem>(`USER#${userId}`, 'FRIEND#');
    for (const f of fss) {
      const items = await queryPartition(`PAIR#${f.pairKey}`);
      await batchDelete(items.filter((i) => i.sk.startsWith('TOPIC#') || i.sk.startsWith('SUMMARY#')));
    }
  },

  'GET /friends/{userId}/calls': async ({ userId, params }) => {
    await requireFriend(userId, params.userId);
    const calls = await queryGsi(`PAIR#${pairKey(userId, params.userId)}`, 'CALL#', { desc: true });
    return {
      calls: calls.map((c) => ({
        callId: c.id,
        startedAt: c.startedAt,
        durationSec: c.endedAt ? Math.round((Date.parse(c.endedAt) - Date.parse(c.startedAt)) / 1000) : 0,
      })),
    };
  },

  'POST /friends/{userId}/call': async ({ userId, params }) => {
    const n = await createDirectNudge(userId, params.userId);
    return nudgeDTO(n, userId);
  },
});
