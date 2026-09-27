/** Derived availability only: no biometrics or full WHOOP records are retained. */
export interface WhoopSignal {
  syncedAt: string;
  sleepStart?: string;
  sleepEnd?: string;
  workoutUntil?: string;
}
export interface WhoopActivity { start: string; end: string; nap?: boolean }
const DAY = 86_400_000;
const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
const minutes = (date: number, tz: string) => {
  const parts = new Intl.DateTimeFormat('en-GB', { timeZone: tz, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(date);
  return Number(parts.find(p => p.type === 'hour')!.value) * 60 + Number(parts.find(p => p.type === 'minute')!.value);
};
const hhmm = (value: number) => `${String(Math.floor(value / 60)).padStart(2, '0')}:${String(value % 60).padStart(2, '0')}`;

export function deriveWhoopSignal(sleeps: WhoopActivity[], workouts: WhoopActivity[], tz: string, now: number,
  options = { sleepEnabled: true, workoutEnabled: true }): WhoopSignal {
  const signal: WhoopSignal = { syncedAt: new Date(now).toISOString() };
  const valid = (r: WhoopActivity) => Number.isFinite(Date.parse(r.start)) && Number.isFinite(Date.parse(r.end))
    && Date.parse(r.start) < Date.parse(r.end) && Date.parse(r.end) <= now && Date.parse(r.end) > now - 7 * DAY;
  const nights = sleeps.filter(r => valid(r) && !r.nap && Date.parse(r.end) - Date.parse(r.start) >= 3 * 3_600_000
    && Date.parse(r.end) - Date.parse(r.start) <= 12 * 3_600_000);
  if (options.sleepEnabled && nights.length >= 3 && Math.max(...nights.map(r => Date.parse(r.end))) > now - 2 * DAY) {
    // Unwrap around noon so 23:30 and 00:30 average to midnight, not midday.
    const start = median(nights.map(r => (minutes(Date.parse(r.start), tz) + 720) % 1440));
    const duration = Math.round(median(nights.map(r => (Date.parse(r.end) - Date.parse(r.start)) / 60_000)));
    signal.sleepStart = hhmm((start + 720) % 1440);
    signal.sleepEnd = hhmm((start + 720 + duration) % 1440);
  }
  const ends = workouts.filter(valid).map(r => Date.parse(r.end) + 30 * 60_000).filter(end => end > now);
  if (options.workoutEnabled && ends.length) signal.workoutUntil = new Date(Math.max(...ends)).toISOString();
  return signal;
}
