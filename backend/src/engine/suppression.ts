// Per-user reasons a nudge must not be sent right now (SPEC NUD-2).
import { isInQuietHours } from './quiet.js';
import { userAllows } from './frequency.js';
import type { Availability, EngineUser } from './types.js';

export const STALE_MS = 48 * 3_600_000;
export const CONTEXT_FRESH_MS = 15 * 60_000;

export type SuppressionReason = 'quiet' | 'focus' | 'driving' | 'busy_nudge' | 'stale' | 'no_availability' | 'frequency';

export interface SuppressionOptions {
  /** Skip the frequency check (used when re-evaluating a nudge that was already counted). */
  ignoreFrequency?: boolean;
  /** Skip the busy-with-nudge check (the pre-check phase owns the reservation). */
  ignoreBusy?: boolean;
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
  if (isInQuietHours(now, user.tz, s.quietStart, s.quietEnd)) r.push('quiet');
  if (!avail?.syncedAt) r.push('no_availability');
  else if (isStale(avail, now)) r.push('stale');
  const fresh = (at?: string) => !!at && now - Date.parse(at) < CONTEXT_FRESH_MS;
  if (s.respectFocus && avail?.focus?.isFocused && fresh(avail.focus.at)) r.push('focus');
  if (s.respectDriving && avail?.driving?.isDriving && fresh(avail.driving.at)) r.push('driving');
  if (!opts.ignoreBusy && user.busyUntil && Date.parse(user.busyUntil) > now) r.push('busy_nudge');
  if (!opts.ignoreFrequency && !userAllows(s.frequency, user.recentNudgeAts, user.lastNudgeAt, now)) r.push('frequency');
  return r;
}
