// Nudge matcher: finds mutual free windows, applies suppression + frequency, and sends nudges (SPEC NUD-1..7).
import { nudgeCopy } from '../engine/copy.js';
import { pairAllows, within24h } from '../engine/frequency.js';
import { mutualFreeWindow } from '../engine/overlap.js';
import { choosePairs, type CandidatePair } from '../engine/pairChoice.js';
import { minutesUntilQuiet } from '../engine/quiet.js';
import { isStale, suppressionReasons } from '../engine/suppression.js';
import { isConditionalFailure, put, queryGsi, queryPrefix, update } from './db.js';
import { applyEvent, enqueueDelay, getNudge, NUDGE_TTL_S, topicFor, type NudgeItem } from './flows.js';
import { K, newId } from './keys.js';
import { payloads, pushToUser } from './push.js';
import { getFriendship, loadAvailability, loadUsers, nameFor, publicUser, type FriendshipItem, type UserItem } from './users.js';

const HORIZON_MIN = 180;
const STALE_NOTICE_MS = 7 * 86_400_000;
const PRECHECK_S = 60;

export interface MatcherOptions {
  now?: number;
  onlyUserIds?: string[];
  /** Run the pre-check inline instead of waiting 60 s (dev hook). */
  immediate?: boolean;
}

export interface MatcherResult {
  considered: number;
  created: string[];
  skipped: Record<string, string[]>;
}

/** Minutes in the mutual free window, capped by either user's quiet hours; null if busy now. */
export function windowMinutes(now: number, ua: UserItem, ub: UserItem, blocksA: any[], blocksB: any[]) {
  const w = mutualFreeWindow(now, blocksA, blocksB, HORIZON_MIN);
  if (!w) return null;
  const quietCap = Math.min(
    minutesUntilQuiet(now, ua.tz, ua.settings.quietStart, ua.settings.quietEnd),
    minutesUntilQuiet(now, ub.tz, ub.settings.quietStart, ub.settings.quietEnd),
  );
  const minutes = Math.floor(Math.min((w.end - now) / 60_000, quietCap));
  return { minutes, end: now + minutes * 60_000 };
}

export async function runMatcher(opts: MatcherOptions = {}): Promise<MatcherResult> {
  const now = opts.now ?? Date.now();
  const only = opts.onlyUserIds ? new Set(opts.onlyUserIds) : undefined;
  const friendships = (await queryGsi<FriendshipItem>('FRIENDSHIPS')).filter(
    (f) => f.a < f.b && (!only || (only.has(f.a) && only.has(f.b))),
  );
  const ids = [...new Set(friendships.flatMap((f) => [f.a, f.b]))];
  const [users, avail] = await Promise.all([loadUsers(ids), loadAvailability(ids)]);
  const result: MatcherResult = { considered: friendships.length, created: [], skipped: {} };

  // Stale-availability notices (at most one per week).
  for (const u of users.values()) {
    const a = avail.get(u.id);
    if (a?.syncedAt && isStale(a, now) && (!u.lastStaleNoticeAt || now - Date.parse(u.lastStaleNoticeAt) > STALE_NOTICE_MS)) {
      await pushToUser(u.id, 'alert', payloads.alert('availability.stale', 'Nudge', 'Open Nudge to keep your availability fresh'));
      await update(K.user(u.id), { lastStaleNoticeAt: new Date(now).toISOString() });
    }
  }

  const candidates: (CandidatePair & { minutes: number; end: number; topic?: { id: string; title: string } })[] = [];
  for (const f of friendships) {
    const ua = users.get(f.a);
    const ub = users.get(f.b);
    if (!ua || !ub) continue;
    const aa = avail.get(f.a);
    const ab = avail.get(f.b);
    const reasons = [...suppressionReasons(ua, aa, now).map((r) => `a:${r}`), ...suppressionReasons(ub, ab, now).map((r) => `b:${r}`)];
    if (!pairAllows(ua.settings.frequency, ub.settings.frequency, f.lastNudgeAt, f.lastCallAt, now)) reasons.push('pair_cooldown');
    const w = reasons.length ? null : windowMinutes(now, ua, ub, aa?.busyBlocks ?? [], ab?.busyBlocks ?? []);
    if (!reasons.length) {
      if (!w) reasons.push('busy_now');
      else if (w.minutes < Math.max(ua.settings.minWindowMin, ub.settings.minWindowMin)) reasons.push('window_too_short');
    }
    if (reasons.length || !w) {
      result.skipped[f.pairKey] = reasons;
      continue;
    }
    const topic = await topicFor(f.pairKey, now);
    candidates.push({ pairKey: f.pairKey, a: f.a, b: f.b, hasDueTopic: !!topic?.due, lastCallAt: f.lastCallAt, minutes: w.minutes, end: w.end, topic });
  }

  for (const c of choosePairs(candidates)) {
    const full = candidates.find((x) => x.pairKey === c.pairKey)!;
    const id = await createPrecheckNudge(full, now);
    if (!id) continue;
    result.created.push(id);
    await Promise.all([c.a, c.b].map((u) => pushToUser(u, 'background', payloads.background('availability.check', id))));
    if (opts.immediate) await precheck(id, now);
    else await enqueueDelay({ kind: 'precheck', nudgeId: id }, PRECHECK_S);
  }
  return result;
}

async function createPrecheckNudge(c: CandidatePair & { minutes: number; end: number; topic?: { id: string; title: string } }, now: number) {
  const id = newId('n');
  const createdAt = new Date(now).toISOString();
  const busyUntil = new Date(now + (PRECHECK_S + NUDGE_TTL_S + 60) * 1000).toISOString();
  const reserved: string[] = [];
  for (const uid of [c.a, c.b]) {
    try {
      await update(
        K.user(uid),
        { activeNudgeId: id, busyUntil },
        { condition: 'attribute_not_exists(busyUntil) OR busyUntil < :now', values: { ':now': createdAt } },
      );
      reserved.push(uid);
    } catch (e) {
      if (!isConditionalFailure(e)) throw e;
      for (const r of reserved) await update(K.user(r), { activeNudgeId: undefined, busyUntil: undefined });
      return undefined;
    }
  }
  const n: NudgeItem = {
    ...K.nudge(id),
    id,
    pairKey: c.pairKey,
    participants: [c.a, c.b],
    kind: 'auto',
    window: { start: createdAt, end: new Date(c.end).toISOString() },
    minutes: c.minutes,
    copyByUser: {},
    topicId: c.topic?.id,
    topicTitle: c.topic?.title,
    state: 'precheck',
    responses: {},
    createdAt,
    version: 1,
    ttl: Math.floor(now / 1000) + 30 * 86_400,
    gsi1pk: `PAIR#${c.pairKey}`,
    gsi1sk: `NUDGE#${createdAt}`,
  };
  await put(n);
  return id;
}

/** Phase 2: re-evaluate with any fresh Focus/driving reports, then send (or cancel). */
export async function precheck(nudgeId: string, nowArg?: number) {
  const n = await getNudge(nudgeId);
  if (n.state !== 'precheck') return n;
  const now = nowArg ?? Date.now();
  const [users, avail] = await Promise.all([loadUsers(n.participants), loadAvailability(n.participants)]);
  const [a, b] = n.participants;
  const ua = users.get(a)!;
  const ub = users.get(b)!;
  const reasons = [
    ...suppressionReasons(ua, avail.get(a), now, { ignoreBusy: true, ignoreFrequency: true }),
    ...suppressionReasons(ub, avail.get(b), now, { ignoreBusy: true, ignoreFrequency: true }),
  ];
  const w = windowMinutes(now, ua, ub, avail.get(a)?.busyBlocks ?? [], avail.get(b)?.busyBlocks ?? []);
  if (reasons.length || !w || w.minutes < Math.max(ua.settings.minWindowMin, ub.settings.minWindowMin)) {
    return applyEvent(nudgeId, { type: 'precheck_failed' });
  }
  const [fsA, fsB] = await Promise.all([getFriendship(a, b), getFriendship(b, a)]);
  const nameForA = nameFor(ub, fsA); // what A calls B
  const nameForB = nameFor(ua, fsB);
  const sentAt = new Date(now).toISOString();
  const expiresAt = new Date(now + NUDGE_TTL_S * 1000).toISOString();
  const copyByUser = { [a]: nudgeCopy(nameForA, w.minutes, n.topicTitle), [b]: nudgeCopy(nameForB, w.minutes, n.topicTitle) };
  const windowEnd = new Date(w.end).toISOString();
  await update(K.nudge(nudgeId), { copyByUser, sentAt, expiresAt, minutes: w.minutes, window: { start: sentAt, end: windowEnd } });
  const sent = await applyEvent(nudgeId, { type: 'sent' });

  // Frequency bookkeeping.
  for (const u of [ua, ub]) {
    await update(K.user(u.id), { recentNudgeAts: [...within24h(u.recentNudgeAts, now), sentAt], lastNudgeAt: sentAt });
  }
  await update(K.friend(a, b), { lastNudgeAt: sentAt });
  await update(K.friend(b, a), { lastNudgeAt: sentAt });
  if (n.topicId) await update(K.topic(n.pairKey, n.topicId), { status: 'suggested', suggestedAt: sentAt }).catch(() => {});

  const expiration = Math.floor(Date.parse(expiresAt) / 1000);
  for (const [uid, friend, name] of [
    [a, ub, nameForA],
    [b, ua, nameForB],
  ] as const) {
    await pushToUser(
      uid,
      'alert',
      payloads.nudge({
        ...copyByUser[uid],
        nudgeId,
        friendId: friend.id,
        friendName: name,
        windowStart: sentAt,
        windowEnd,
        minutes: w.minutes,
        avatarUrl: (await publicUser(friend)).avatarUrl,
      }),
      { expiration, collapseId: nudgeId.slice(0, 64) },
    );
  }
  await enqueueDelay({ kind: 'expire', nudgeId }, NUDGE_TTL_S);
  return sent;
}

export async function expireNudge(nudgeId: string) {
  const n = await getNudge(nudgeId);
  if (n.state !== 'pending' && n.state !== 'accepted_by_one') return n;
  if (n.expiresAt && Date.parse(n.expiresAt) > Date.now() + 5_000) return n; // not due (e.g. a re-used id)
  return applyEvent(nudgeId, { type: 'expire' });
}

/** Dev hook: force expiry regardless of time. */
export const forceExpire = (nudgeId: string) => applyEvent(nudgeId, { type: 'expire' });
