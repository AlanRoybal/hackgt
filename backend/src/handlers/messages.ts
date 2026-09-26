// Conversations and per-friend message threads (SPEC MSG-1/2).
import { query, queryPrefix, update } from '../lib/db.js';
import { bad, forbidden, router } from '../lib/http.js';
import { pairKey } from '../lib/keys.js';
import { deliverMessage, messageDTO, putMessage, type MessageItem } from '../lib/messages.js';
import { getFriendship, loadUsers, publicUser, type FriendshipItem } from '../lib/users.js';

const recent = (pk: string, limit: number, before?: string) =>
  query<MessageItem>(
    {
      KeyConditionExpression: before ? 'pk = :pk AND sk BETWEEN :lo AND :hi' : 'pk = :pk AND begins_with(sk, :p)',
      ExpressionAttributeValues: before
        ? { ':pk': `PAIR#${pk}`, ':lo': 'MSG#', ':hi': `MSG#${before}` }
        : { ':pk': `PAIR#${pk}`, ':p': 'MSG#' },
      ScanIndexForward: false,
      Limit: limit,
    },
    false,
  );

const isUnread = (m: MessageItem, me: string) => m.senderId !== me && !(m.readBy ?? []).includes(me);

async function requireFriend(me: string, other: string) {
  const fs = await getFriendship(me, other);
  if (!fs) throw forbidden('not_friends');
  return fs;
}

export const handler = router({
  'GET /conversations': async ({ userId }) => {
    const fss = await queryPrefix<FriendshipItem>(`USER#${userId}`, 'FRIEND#');
    const users = await loadUsers(fss.map((f) => f.b));
    const convs = await Promise.all(
      fss
        .filter((f) => users.has(f.b))
        .map(async (f) => {
          const msgs = await recent(f.pairKey, 50);
          return {
            friend: await publicUser(users.get(f.b)!),
            nickname: f.nickname,
            lastMessage: msgs[0] ? messageDTO(msgs[0], userId) : undefined,
            unread: msgs.filter((m) => isUnread(m, userId)).length,
          };
        }),
    );
    convs.sort((a, b) => (b.lastMessage?.createdAt ?? '').localeCompare(a.lastMessage?.createdAt ?? ''));
    return { conversations: convs };
  },

  'GET /friends/{userId}/messages': async ({ userId, params, query: q }) => {
    await requireFriend(userId, params.userId);
    const before = q.before && !Number.isNaN(Date.parse(q.before)) ? q.before : undefined;
    const msgs = await recent(pairKey(userId, params.userId), 50, before);
    return { messages: msgs.filter((m) => !before || m.createdAt < before).map((m) => messageDTO(m, userId)) };
  },

  'POST /friends/{userId}/messages': async ({ userId, params, body }) => {
    await requireFriend(userId, params.userId);
    const text = typeof body.body === 'string' ? body.body.trim() : '';
    if (!text || text.length > 1000) throw bad('invalid_body');
    const m = await putMessage(userId, params.userId, { senderId: userId, body: text, kind: 'user' });
    await deliverMessage(m, { pushTo: params.userId });
    return messageDTO(m, userId);
  },

  'POST /friends/{userId}/messages/read': async ({ userId, params }) => {
    await requireFriend(userId, params.userId);
    const msgs = await recent(pairKey(userId, params.userId), 50);
    await Promise.all(
      msgs.filter((m) => isUnread(m, userId)).map((m) => update({ pk: m.pk, sk: m.sk }, { readBy: [...(m.readBy ?? []), userId] })),
    );
  },
});
