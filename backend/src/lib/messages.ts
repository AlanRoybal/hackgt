// Per-pair message threads (SPEC MSG-1).
import { put } from './db.js';
import { newId, pairKey, pairMembers } from './keys.js';
import { payloads, pushToUser } from './push.js';
import { getFriendship, loadUsers, nameFor } from './users.js';
import { sendToUser } from './ws.js';

export type MessageKind = 'user' | 'auto_followup' | 'system';

export interface MessageItem {
  pk: string;
  sk: string;
  id: string;
  pairKey: string;
  senderId: string;
  body: string;
  kind: MessageKind;
  systemEvent?: Record<string, unknown>;
  createdAt: string;
  readBy: string[];
}

export function messageDTO(m: MessageItem, viewerId: string) {
  const [x, y] = pairMembers(m.pairKey);
  return {
    id: m.id,
    friendId: x === viewerId ? y : x,
    senderId: m.senderId,
    body: m.body,
    kind: m.kind,
    createdAt: m.createdAt,
    ...(m.systemEvent ? { systemEvent: m.systemEvent } : {}),
  };
}

export async function putMessage(a: string, b: string, m: { senderId: string; body: string; kind: MessageKind; systemEvent?: Record<string, unknown> }) {
  const pk = pairKey(a, b);
  const createdAt = new Date().toISOString();
  const id = newId('m');
  const item: MessageItem = {
    pk: `PAIR#${pk}`,
    sk: `MSG#${createdAt}#${id}`,
    id,
    pairKey: pk,
    createdAt,
    readBy: m.senderId === 'system' ? [] : [m.senderId],
    ...m,
  };
  await put(item);
  return item;
}

/**
 * Delivers a message to both members over WebSocket; `pushTo` also gets an APNs alert
 * titled with their nickname for the sender.
 */
export async function deliverMessage(item: MessageItem, opts: { pushTo?: string } = {}) {
  const [x, y] = pairMembers(item.pairKey);
  await Promise.all([x, y].map((uid) => sendToUser(uid, { type: 'message.new', friendId: uid === x ? y : x, message: messageDTO(item, uid) })));
  if (opts.pushTo) {
    const from = item.senderId;
    const users = await loadUsers([from]);
    const fs = await getFriendship(opts.pushTo, from);
    await pushToUser(opts.pushTo, 'alert', payloads.message({ friendId: from, title: nameFor(users.get(from), fs), body: item.body }));
  }
}
