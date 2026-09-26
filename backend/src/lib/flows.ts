import { commitNudgeTransition, isTransitionConflict } from './adaptive.js';
// Nudge + call orchestration: state transitions, their side effects, and DTOs.
import { SendMessageCommand, SQSClient } from '@aws-sdk/client-sqs';
import { followUpMessage } from '../ai/followup.js';
import { stepDown } from '../engine/frequency.js';
import { isTerminal, transition, type Effect, type NudgeEvent } from '../engine/state.js';
import type { NudgeResponse, NudgeState } from '../engine/types.js';
import { createMeeting, deleteMeeting, startTranscription } from './chime.js';
import { get, isConditionalFailure, put, queryPrefix, update } from './db.js';
import { env } from './env.js';
import { HttpError, notFound } from './http.js';
import { K, newId, pairKey } from './keys.js';
import { deliverMessage, putMessage } from './messages.js';
import { payloads, pushToUser } from './push.js';
import { getFriendship, getUser, loadUsers, nameFor, publicUser, type UserItem } from './users.js';
import { connectionsFor, sendToUser } from './ws.js';

export interface NudgeItem {
  pk: string;
  sk: string;
  id: string;
  pairKey: string;
  participants: [string, string];
  kind: 'auto' | 'direct';
  initiatorId?: string;
  window: { start: string; end: string };
  minutes: number;
  copyByUser: Record<string, { title: string; body: string }>;
  topicId?: string;
  topicTitle?: string;
  state: NudgeState;
  responses: Record<string, NudgeResponse | undefined>;
  sentAt?: string;
  expiresAt?: string;
  callId?: string;
  createdAt: string;
  version: number;
  ttl: number;
  gsi1pk: string;
  gsi1sk: string;
}

export interface CallItem {
  pk: string;
  sk: string;
  id: string;
  nudgeId: string;
  pairKey: string;
  participants: [string, string];
  chimeMeetingId: string;
  meeting: any;
  attendees: Record<string, any>;
  startedAt: string;
  endedAt?: string;
  memoryAllowed: boolean;
  summarized?: boolean;
  gsi1pk: string;
  gsi1sk: string;
}

const sqs = new SQSClient({});
export const NUDGE_TTL_S = 180;
const CALL_BUSY_MS = 3 * 3_600_000;

export const otherOf = (parts: [string, string], id: string) => (parts[0] === id ? parts[1] : parts[0]);

export async function getNudge(id: string): Promise<NudgeItem> {
  const n = await get<NudgeItem>(K.nudge(id), true);
  if (!n) throw notFound('nudge_not_found');
  return n;
}

export async function getCall(id: string): Promise<CallItem> {
  const c = await get<CallItem>(K.call(id));
  if (!c) throw notFound('call_not_found');
  return c;
}

export async function enqueueDelay(body: { kind: 'precheck' | 'expire'; nudgeId: string }, delaySeconds: number) {
  await sqs.send(new SendMessageCommand({ QueueUrl: env.delayQueueUrl, MessageBody: JSON.stringify(body), DelaySeconds: delaySeconds }));
}

export async function enqueueSummarize(callId: string, delaySeconds = 30) {
  await sqs.send(new SendMessageCommand({ QueueUrl: env.summarizeQueueUrl, MessageBody: JSON.stringify({ callId }), DelaySeconds: delaySeconds }));
}

// DTOs ----------------------------------------------------------------------------------------

export async function nudgeDTO(n: NudgeItem, viewerId: string, users?: Map<string, UserItem>) {
  const friendId = otherOf(n.participants, viewerId);
  const friend = users?.get(friendId) ?? (await getUser(friendId));
  const fs = await getFriendship(viewerId, friendId);
  const copy = n.copyByUser[viewerId] ?? { title: '', body: '' };
  return {
    id: n.id,
    kind: n.kind,
    friend: await publicUser(friend),
    nickname: fs?.nickname,
    state: n.state,
    myResponse: n.responses[viewerId],
    theirResponse: n.responses[friendId],
    window: n.window,
    minutes: n.minutes,
    title: copy.title,
    body: copy.body,
    topic: n.topicId ? { id: n.topicId, title: n.topicTitle ?? '' } : undefined,
    expiresAt: n.expiresAt,
    callId: n.callId,
  };
}

/**
 * Topics store followUpAfter as a calendar day ("YYYY-MM-DD", compared as a string by the matcher). Clients decode
 * dates as ISO-8601 timestamps, so send midnight UTC; a bare day made the whole memories payload undecodable.
 */
export function topicDTO(t: Record<string, any>) {
  const f = typeof t.followUpAfter === 'string' ? t.followUpAfter : undefined;
  return {
    id: t.id,
    title: t.title,
    aboutUserId: t.aboutUserId,
    summary: t.summary,
    followUpAfter: f && /^\d{4}-\d{2}-\d{2}$/.test(f) ? `${f}T00:00:00.000Z` : f,
    status: t.status,
    sourceCallId: t.sourceCallId,
  };
}

export async function broadcastNudge(n: NudgeItem) {
  const users = await loadUsers(n.participants);
  await Promise.all(
    n.participants.map(async (uid) => sendToUser(uid, { type: 'nudge.updated', nudge: await nudgeDTO(n, uid, users) })),
  );
}

// Transitions --------------------------------------------------------------------------------

/** Applies an event with optimistic locking, runs its effects, and broadcasts the new state. */
export async function applyEvent(nudgeId: string, event: NudgeEvent): Promise<NudgeItem> {
  for (let attempt = 0; attempt < 4; attempt++) {
    const n = await getNudge(nudgeId);
    const t = transition({ state: n.state, participants: n.participants, responses: n.responses }, event);
    if (!t.ok) throw new HttpError(409, t.error ?? 'invalid_state');
    let updated: NudgeItem;
    try {
      updated = await commitNudgeTransition(n, t.next, event);
    } catch (e) {
      if (isConditionalFailure(e) || isTransitionConflict(e)) continue;
      throw e;
    }
    for (const eff of t.effects) {
      try {
        updated = (await runEffect(updated, eff, 'userId' in event ? event.userId : undefined)) ?? updated;
      } catch (e) {
        console.error('effect failed', eff.type, e);
      }
    }
    await broadcastNudge(updated);
    return updated;
  }
  throw new HttpError(409, 'conflict');
}

async function runEffect(n: NudgeItem, eff: Effect, actorId?: string): Promise<NudgeItem | void> {
  switch (eff.type) {
    case 'create_call':
      return createCallForNudge(n, actorId);
    case 'cleanup':
      await releaseUsers(n);
      await Promise.all(n.participants.map((u) => pushToUser(u, 'background', payloads.background('nudge.cleanup', n.id))));
      return;
    case 'missed_event': {
      const [a, b] = n.participants;
      const m = await putMessage(a, b, {
        senderId: 'system',
        body: 'Missed nudge',
        kind: 'system',
        systemEvent: { type: 'missed_nudge', at: n.sentAt ?? n.createdAt },
      });
      await deliverMessage(m);
      return;
    }
    case 'step_down_frequency': {
      const u = await getUser(eff.userId);
      const next = stepDown(u.settings.frequency);
      if (next !== u.settings.frequency) {
        await update(K.user(u.id), { settings: { ...u.settings, frequency: next }, frequencyBeforeLess: u.settings.frequency });
      }
      return;
    }
    case 'follow_up': {
      const from = await getUser(eff.fromUserId);
      if (from.settings.skipBehavior !== 'message') return;
      const body = await followUpMessage();
      const m = await putMessage(eff.fromUserId, eff.toUserId, { senderId: eff.fromUserId, body, kind: 'auto_followup' });
      await deliverMessage(m, { pushTo: eff.toUserId });
      return;
    }
  }
}

/** Clears the nudge reservation on both users (only if it still points at this nudge). */
export async function releaseUsers(n: NudgeItem) {
  await Promise.all(
    n.participants.map(async (uid) => {
      try {
        await update(
          K.user(uid),
          { activeNudgeId: undefined, busyUntil: undefined },
          { condition: 'activeNudgeId = :id AND attribute_not_exists(activeCallId)', values: { ':id': n.id } },
        );
      } catch (e) {
        if (!isConditionalFailure(e)) throw e;
      }
    }),
  );
}

async function createCallForNudge(n: NudgeItem, actorId?: string): Promise<NudgeItem> {
  const callId = newId('c');
  const users = await loadUsers(n.participants);
  const { meeting, attendees } = await createMeeting(callId, n.participants);
  await startTranscription(meeting.MeetingId!);
  const now = new Date().toISOString();
  const memoryAllowed = n.participants.every((u) => users.get(u)?.settings.memoryEnabled !== false);
  const call: CallItem = {
    ...K.call(callId),
    id: callId,
    nudgeId: n.id,
    pairKey: n.pairKey,
    participants: n.participants,
    chimeMeetingId: meeting.MeetingId!,
    meeting,
    attendees,
    startedAt: now,
    memoryAllowed,
    gsi1pk: `PAIR#${n.pairKey}`,
    gsi1sk: `CALL#${now}`,
  };
  await put(call);
  const updated = (await update(K.nudge(n.id), { callId })) as NudgeItem;
  const busyUntil = new Date(Date.now() + CALL_BUSY_MS).toISOString();
  await Promise.all(n.participants.map((u) => update(K.user(u), { activeCallId: callId, activeNudgeId: n.id, busyUntil })));
  await notifyMatched(updated, callId, users, actorId);
  return updated;
}

/**
 * The person whose accept completed the match is in the app by definition, and waiting-room participants too:
 * both get call.matched over WS. Anyone else gets a VoIP push (CallKit rings). The actor is never rung, which
 * avoids a race where their `waiting` WS message lands after their accept.
 */
async function notifyMatched(n: NudgeItem, callId: string, users: Map<string, UserItem>, actorId?: string) {
  await Promise.all(
    n.participants.map(async (uid) => {
      const conns = await connectionsFor(uid);
      const waiting = uid === actorId || conns.some((c) => c.waitingNudgeId === n.id);
      if (waiting) {
        await sendToUser(uid, { type: 'call.matched', callId, nudgeId: n.id });
      } else {
        const caller = otherOf(n.participants, uid);
        const fs = await getFriendship(uid, caller);
        await pushToUser(uid, 'voip', payloads.voip({ callId, nudgeId: n.id, callerId: caller, callerName: nameFor(users.get(caller), fs) }));
      }
    }),
  );
}

/** Ends a call for both sides (idempotent). */
export async function endCall(callId: string, byUserId?: string): Promise<CallItem> {
  const call = await getCall(callId);
  if (call.endedAt) return call;
  const endedAt = new Date().toISOString();
  let ended: CallItem;
  try {
    ended = (await update(K.call(callId), { endedAt }, { condition: 'attribute_not_exists(endedAt)' })) as CallItem;
  } catch (e) {
    if (isConditionalFailure(e)) return getCall(callId);
    throw e;
  }
  await deleteMeeting(call.chimeMeetingId);
  try {
    await applyEvent(call.nudgeId, { type: 'end' });
  } catch (e) {
    if (!(e instanceof HttpError)) throw e;
  }
  const durationSec = Math.max(0, Math.round((Date.parse(endedAt) - Date.parse(call.startedAt)) / 1000));
  await Promise.all(
    call.participants.map(async (uid) => {
      try {
        await update(
          K.user(uid),
          { activeCallId: undefined, activeNudgeId: undefined, busyUntil: undefined },
          { condition: 'activeCallId = :c', values: { ':c': callId } },
        );
      } catch (e) {
        if (!isConditionalFailure(e)) throw e;
      }
    }),
  );
  const [a, b] = call.participants;
  await Promise.all([update(K.friend(a, b), { lastCallAt: endedAt }), update(K.friend(b, a), { lastCallAt: endedAt })].map((p) => p.catch(() => {})));
  // Topics suggested before this call are now "used".
  const topics = await queryPrefix(`PAIR#${call.pairKey}`, 'TOPIC#');
  await Promise.all(topics.filter((t) => t.status === 'suggested').map((t) => update({ pk: t.pk, sk: t.sk }, { status: 'used' })));
  const minutes = Math.max(1, Math.round(durationSec / 60));
  const m = await putMessage(a, b, { senderId: 'system', body: `Called · ${minutes} min`, kind: 'system', systemEvent: { type: 'call', durationSec, callId } });
  await deliverMessage(m);
  await Promise.all(call.participants.filter((u) => u !== byUserId).map((u) => sendToUser(u, { type: 'call.ended', callId })));
  await enqueueSummarize(callId);
  return ended;
}

/** Creates a direct "Call now" nudge with the caller pre-accepted (D-10). */
export async function createDirectNudge(callerId: string, friendId: string): Promise<NudgeItem> {
  const users = await loadUsers([callerId, friendId]);
  const caller = users.get(callerId)!;
  const friend = users.get(friendId);
  if (!friend) throw notFound('user_not_found');
  const now = Date.now();
  for (const u of [caller, friend]) {
    if (u.busyUntil && Date.parse(u.busyUntil) > now) throw new HttpError(409, u.id === callerId ? 'you_are_busy' : 'friend_busy');
  }
  const [fsCaller, fsFriend] = await Promise.all([getFriendship(callerId, friendId), getFriendship(friendId, callerId)]);
  if (!fsCaller) throw new HttpError(403, 'not_friends');
  const recipientSees = nameFor(caller, fsFriend);
  const callerSees = nameFor(friend, fsCaller);
  const id = newId('n');
  const createdAt = new Date(now).toISOString();
  const expiresAt = new Date(now + NUDGE_TTL_S * 1000).toISOString();
  const pk = pairKey(callerId, friendId);
  const n: NudgeItem = {
    ...K.nudge(id),
    id,
    pairKey: pk,
    participants: [callerId, friendId],
    kind: 'direct',
    initiatorId: callerId,
    window: { start: createdAt, end: expiresAt },
    minutes: 0,
    copyByUser: {
      [friendId]: { title: `${recipientSees} wants to call`, body: `${recipientSees} wants to call. Free?` },
      [callerId]: { title: `Calling ${callerSees}`, body: `Waiting for ${callerSees}…` },
    },
    state: 'accepted_by_one',
    responses: { [callerId]: 'accepted' },
    sentAt: createdAt,
    expiresAt,
    createdAt,
    version: 1,
    ttl: Math.floor(now / 1000) + 30 * 86_400,
    gsi1pk: `PAIR#${pk}`,
    gsi1sk: `NUDGE#${createdAt}`,
  };
  await put(n);
  // The caller is looking at the waiting room: mark their sockets now so a fast accept can't beat the client's
  // own `waiting` message and ring them over VoIP instead of sending call.matched.
  const callerConns = await connectionsFor(callerId);
  await Promise.all(callerConns.map((c) => update(K.conn(c.connectionId), { waitingNudgeId: id }, { condition: 'attribute_exists(pk)' }).catch(() => {})));
  const busyUntil = new Date(now + (NUDGE_TTL_S + 60) * 1000).toISOString();
  await Promise.all([callerId, friendId].map((u) => update(K.user(u), { activeNudgeId: id, busyUntil })));
  await pushToUser(
    friendId,
    'alert',
    payloads.nudge({
      ...n.copyByUser[friendId],
      nudgeId: id,
      friendId: callerId,
      friendName: recipientSees,
      windowStart: n.window.start,
      windowEnd: n.window.end,
      minutes: 0,
      avatarUrl: (await publicUser(caller)).avatarUrl,
    }),
    { expiration: Math.floor(Date.parse(expiresAt) / 1000) },
  );
  await broadcastNudge(n);
  await enqueueDelay({ kind: 'expire', nudgeId: id }, NUDGE_TTL_S);
  return n;
}

/** The user's current non-terminal nudge, if any. */
export async function activeNudgeFor(user: UserItem): Promise<NudgeItem | null> {
  if (!user.activeNudgeId) return null;
  const n = await get<NudgeItem>(K.nudge(user.activeNudgeId));
  if (!n || isTerminal(n.state) || n.state === 'precheck') return null;
  return n;
}
