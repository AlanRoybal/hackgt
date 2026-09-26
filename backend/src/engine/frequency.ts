// Frequency levels (SPEC §3.6).
import type { Frequency } from './types.js';

const H = 3_600_000;
const M = 60_000;

export const LEVELS: Record<Frequency, { dailyCap: number; pairCooldownMs: number; minGapMs: number }> = {
  off: { dailyCap: 0, pairCooldownMs: Infinity, minGapMs: Infinity },
  low: { dailyCap: 1, pairCooldownMs: 72 * H, minGapMs: 6 * H },
  normal: { dailyCap: 3, pairCooldownMs: 24 * H, minGapMs: 2 * H },
  high: { dailyCap: 6, pairCooldownMs: 8 * H, minGapMs: 45 * M },
};

const ORDER: Frequency[] = ['off', 'low', 'normal', 'high'];

/** "See this less often": one level down, floored at Low (only Settings can choose Off). */
export function stepDown(f: Frequency): Frequency {
  if (f === 'off' || f === 'low') return f;
  return ORDER[ORDER.indexOf(f) - 1];
}

/** The stricter of two levels. */
export const stricter = (a: Frequency, b: Frequency): Frequency =>
  ORDER[Math.min(ORDER.indexOf(a), ORDER.indexOf(b))];

/** Timestamps within the last 24 h. */
export const within24h = (ats: string[] | undefined, now: number) =>
  (ats ?? []).filter((t) => now - Date.parse(t) < 24 * H && Date.parse(t) <= now);

/** Whether a user may receive another nudge now under their level. */
export function userAllows(level: Frequency, recentNudgeAts: string[] | undefined, lastNudgeAt: string | undefined, now: number): boolean {
  const L = LEVELS[level];
  if (L.dailyCap === 0) return false;
  if (within24h(recentNudgeAts, now).length >= L.dailyCap) return false;
  if (lastNudgeAt && now - Date.parse(lastNudgeAt) < L.minGapMs) return false;
  return true;
}

/** Pair cooldown, measured from the later of the last nudge and last call, using the stricter level. */
export function pairAllows(a: Frequency, b: Frequency, lastNudgeAt: string | undefined, lastCallAt: string | undefined, now: number): boolean {
  const L = LEVELS[stricter(a, b)];
  if (L.dailyCap === 0) return false;
  const last = Math.max(lastNudgeAt ? Date.parse(lastNudgeAt) : -Infinity, lastCallAt ? Date.parse(lastCallAt) : -Infinity);
  return !(now - last < L.pairCooldownMs);
}
