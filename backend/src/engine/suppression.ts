import { adaptiveDecision, recentSamples } from './adaptive.js';
// Per-user reasons a nudge must not be sent right now (SPEC NUD-2).
import { isInQuietHours } from './quiet.js';
import { userAllows } from './frequency.js';
import { becameBusyAt } from './overlap.js';
import type { Availability, EngineUser } from './types.js';

export const STALE_MS = 48 * 3_600_000;
export const CONTEXT_FRESH_MS = 15 * 60_000;

export type SuppressionReason = 'quiet' | 'focus' | 'driving' | 'busy_nudge' | 'stale' | 'no_availability' | 'frequency' | 'whoop_sleep' | 'whoop_workout' | 'paused' | 'adaptive_backoff' | 'adaptive_timing';

export interface SuppressionOptions {
  /** Skip the frequency check (used when re-evaluating a nudge that was already counted). */
  ignoreFrequency?: boolean;
  /** Skip the busy-with-nudge check (the pre-check phase owns the reservation). */
  ignoreBusy?: boolean;
  /** When the pair last became busy; limits reset from the later of this and the user's own busy start. */
  resetAt?: number;
}

export function isStale(avail: Availability | undefined, now: number): boolean {
  if (!avail?.syncedAt) return true;
  return now - Date.parse(avail.syncedAt) > STALE_MS;
}

export function suppressionReasons(
  user: EngineUser,
  avail: Availability | undefined,
  now: number,
  opts: SuppressionOptions = {},
): SuppressionReason[] {
  const r: SuppressionReason[] = [];
  const s = user.settings;
  if (user.nudgePausedUntil && Date.parse(user.nudgePausedUntil) > now) r.push('paused');
  const adaptive = adaptiveDecision(user.adaptive, user.tz, now);
  // Becoming busy (e.g. a calendar event) resets the frequency limits and any backoff from earlier responses.
  const own = becameBusyAt(avail, now);
  const busyAt = own === undefined ? opts.resetAt : opts.resetAt === undefined ? own : Math.max(own, opts.resetAt);
  const lastResponse = recentSamples(user.adaptive, now).at(-1);
  const busySinceResponse = busyAt !== undefined && (!lastResponse || busyAt > Date.parse(lastResponse.at));
  if (adaptive.cooldownUntil > now && !busySinceResponse) r.push('adaptive_backoff');
  if (adaptive.timingDeferred) r.push('adaptive_timing');
  const whoop = avail?.whoop;
  const age = whoop ? now - Date.parse(whoop.syncedAt) : Infinity;
  if (whoop && age >= 0 && age < CONTEXT_FRESH_MS) {
    if (whoop.sleepStart && whoop.sleepEnd && isInQuietHours(now, user.tz, whoop.sleepStart, whoop.sleepEnd)) r.push('whoop_sleep');
    if (whoop.workoutUntil && Date.parse(whoop.workoutUntil) > now) r.push('whoop_workout');
  }
  if (isInQuietHours(now, user.tz, s.quietStart, s.quietEnd)) r.push('quiet');
  if (!avail?.syncedAt) r.push('no_availability');
  else if (isStale(avail, now)) r.push('stale');
  const fresh = (at?: string) => !!at && now - Date.parse(at) < CONTEXT_FRESH_MS;
  if (s.respectFocus && avail?.focus?.isFocused && fresh(avail.focus.at)) r.push('focus');
  if (s.respectDriving && avail?.driving?.isDriving && fresh(avail.driving.at)) r.push('driving');
  if (!opts.ignoreBusy && user.busyUntil && Date.parse(user.busyUntil) > now) r.push('busy_nudge');
  if (!opts.ignoreFrequency && !userAllows(s.frequency, user.recentNudgeAts, user.lastNudgeAt, now, busyAt)) r.push('frequency');
  return r;
}
