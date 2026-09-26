// Quiet hours evaluated in each user's local time zone.

const parseHm = (hm: string) => {
  const m = /^(\d{1,2}):(\d{2})$/.exec(hm);
  if (!m) return 0;
  return (Number(m[1]) % 24) * 60 + (Number(m[2]) % 60);
};

/** Minutes since local midnight in `tz` at instant `now`. Falls back to UTC for unknown zones. */
export function localMinutes(now: number, tz: string): number {
  let fmt: Intl.DateTimeFormat;
  try {
    fmt = new Intl.DateTimeFormat('en-US', { timeZone: tz, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
  } catch {
    fmt = new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
  }
  const parts = fmt.formatToParts(new Date(now));
  const h = Number(parts.find((p) => p.type === 'hour')?.value ?? 0) % 24;
  const m = Number(parts.find((p) => p.type === 'minute')?.value ?? 0);
  return h * 60 + m;
}

/** True when local time is within [quietStart, quietEnd). Equal start/end means no quiet hours. */
export function isInQuietHours(now: number, tz: string, quietStart: string, quietEnd: string): boolean {
  const s = parseHm(quietStart);
  const e = parseHm(quietEnd);
  if (s === e) return false;
  const t = localMinutes(now, tz);
  return s < e ? t >= s && t < e : t >= s || t < e;
}

/**
 * Minutes until quiet hours begin (∞ if there are none). Computed from wall-clock minutes,
 * so it can be off by the DST shift on transition days — acceptable for capping a nudge window.
 */
export function minutesUntilQuiet(now: number, tz: string, quietStart: string, quietEnd: string): number {
  const s = parseHm(quietStart);
  if (s === parseHm(quietEnd)) return Infinity;
  const t = localMinutes(now, tz);
  const diff = (s - t + 1440) % 1440;
  return diff === 0 ? 1440 : diff;
}
