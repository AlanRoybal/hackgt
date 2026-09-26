// Temporary, explainable adaptation. Never changes the user's frequency setting.
import { localMinutes } from './quiet.js';
export const HOUR = 3_600_000;
const DAY = 24 * HOUR;
export interface ResponseSample { id: string; at: string; offeredAt: string; outcome: 'accept' | 'skip' | 'expired' }
export interface AdaptiveHistory { samples: ResponseSample[] }
export function recentSamples(history: AdaptiveHistory | undefined, now: number): ResponseSample[] {
  return (history?.samples ?? []).filter(s => Number.isFinite(Date.parse(s.at)) && Date.parse(s.at) <= now && now - Date.parse(s.at) < 28 * DAY)
    .sort((a, b) => Date.parse(a.at) - Date.parse(b.at)).slice(-100);
}
export function appendResponse(history: AdaptiveHistory | undefined, sample: ResponseSample, now: number): AdaptiveHistory {
  return { samples: recentSamples({ samples: [...(history?.samples ?? []).filter(s => s.id !== sample.id), sample] }, now) };
}
export function adaptiveDecision(history: AdaptiveHistory | undefined, tz: string, now: number) {
  const samples = recentSamples(history, now);
  let pressure = 0;
  let previous = samples.length ? Date.parse(samples[0].at) : now;
  for (const s of samples) {
    const at = Date.parse(s.at);
    pressure *= 2 ** (-(at - previous) / (2 * DAY));
    pressure = Math.max(0, Math.min(6, pressure + (s.outcome === 'accept' ? -2 : s.outcome === 'skip' ? 1 : 0.35)));
    previous = at;
  }
  const last = samples.at(-1);
  const cooldownUntil = last && last.outcome !== 'accept' && pressure >= 1.5
    ? previous + Math.min(24, pressure * 6) * HOUR : 0;
  // Learn broad local-time preferences only after observations on at least 3 different days.
  const slot = Math.floor(localMinutes(now, tz) / 180);
  const matching = samples.filter(s => Number.isFinite(Date.parse(s.offeredAt)) && Math.floor(localMinutes(Date.parse(s.offeredAt), tz) / 180) === slot);
  const days = new Set(matching.map(s => {
    try { return new Intl.DateTimeFormat('en-CA', { timeZone: tz }).format(new Date(s.offeredAt)); }
    catch { return s.offeredAt.slice(0, 10); }
  }));
  let preference = 0;
  if (days.size >= 3) for (const s of matching) {
    preference += (s.outcome === 'accept' ? 1 : s.outcome === 'skip' ? -1 : -0.25) * 2 ** (-(now - Date.parse(s.at)) / (7 * DAY));
  }
  // Only defer the first hour of an unfavorable 3-hour slot; remaining hours permit exploration.
  const timingDeferred = preference <= -2 && localMinutes(now, tz) % 180 < 60;
  return { cooldownUntil, timingDeferred, preference, pressure: pressure * 2 ** (-(now - previous) / (2 * DAY)) };
}
