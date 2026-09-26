import { describe, expect, it } from 'vitest';
import { isInQuietHours, localMinutes, minutesUntilQuiet } from '../src/engine/quiet.js';
import { suppressionReasons } from '../src/engine/suppression.js';
import { DEFAULT_SETTINGS, type EngineUser } from '../src/engine/types.js';

const T = (s: string) => Date.parse(s);

describe('quiet hours', () => {
  it('handles ranges crossing midnight in the user time zone', () => {
    // 23:30 in New York (EDT, UTC-4) = 03:30Z next day
    expect(isInQuietHours(T('2026-09-27T03:30:00Z'), 'America/New_York', '23:00', '07:00')).toBe(true);
    expect(isInQuietHours(T('2026-09-27T12:00:00Z'), 'America/New_York', '23:00', '07:00')).toBe(false);
    // default 00:00–08:00
    expect(isInQuietHours(T('2026-09-26T07:30:00Z'), 'America/Los_Angeles', '00:00', '08:00')).toBe(true); // 00:30 PDT
    expect(isInQuietHours(T('2026-09-26T15:30:00Z'), 'America/Los_Angeles', '00:00', '08:00')).toBe(false); // 08:30 PDT
  });

  it('equal start and end means no quiet hours', () => {
    expect(isInQuietHours(T('2026-09-26T03:00:00Z'), 'UTC', '00:00', '00:00')).toBe(false);
    expect(minutesUntilQuiet(T('2026-09-26T03:00:00Z'), 'UTC', '00:00', '00:00')).toBe(Infinity);
  });

  it('uses local wall-clock time across DST transitions', () => {
    // US DST ends 2026-11-01 at 02:00 local. 07:30Z Nov 1 = 02:30 EST (after fall back); 05:30Z = 01:30 EDT.
    expect(localMinutes(T('2026-11-01T07:30:00Z'), 'America/New_York')).toBe(2 * 60 + 30);
    expect(localMinutes(T('2026-11-01T05:30:00Z'), 'America/New_York')).toBe(1 * 60 + 30);
    // Spring forward 2026-03-08: 07:30Z = 03:30 EDT (02:xx does not exist).
    expect(localMinutes(T('2026-03-08T07:30:00Z'), 'America/New_York')).toBe(3 * 60 + 30);
    expect(isInQuietHours(T('2026-03-08T07:30:00Z'), 'America/New_York', '00:00', '08:00')).toBe(true);
  });

  it('minutes until quiet start', () => {
    expect(minutesUntilQuiet(T('2026-09-26T23:40:00Z'), 'UTC', '00:00', '08:00')).toBe(20);
  });

  it('unknown time zones fall back to UTC instead of throwing', () => {
    expect(localMinutes(T('2026-09-26T10:05:00Z'), 'Not/AZone')).toBe(605);
  });
});

describe('suppressionReasons', () => {
  const now = T('2026-09-26T18:00:00Z'); // 18:00 UTC
  const user = (over: Partial<EngineUser> = {}): EngineUser => ({ id: 'u', tz: 'UTC', settings: { ...DEFAULT_SETTINGS }, ...over });
  const fresh = { busyBlocks: [], syncedAt: new Date(now - 3_600_000).toISOString() };

  it('clean user has no reasons', () => {
    expect(suppressionReasons(user(), fresh, now)).toEqual([]);
  });
  it('quiet hours', () => {
    expect(suppressionReasons(user({ settings: { ...DEFAULT_SETTINGS, quietStart: '17:00', quietEnd: '19:00' } }), fresh, now)).toContain('quiet');
  });
  it('focus reported within 15 minutes, only when respectFocus', () => {
    const a = { ...fresh, focus: { isFocused: true, at: new Date(now - 5 * 60_000).toISOString() } };
    expect(suppressionReasons(user(), a, now)).toContain('focus');
    expect(suppressionReasons(user({ settings: { ...DEFAULT_SETTINGS, respectFocus: false } }), a, now)).not.toContain('focus');
    const old = { ...fresh, focus: { isFocused: true, at: new Date(now - 20 * 60_000).toISOString() } };
    expect(suppressionReasons(user(), old, now)).not.toContain('focus');
  });
  it('driving reported within 15 minutes', () => {
    const a = { ...fresh, driving: { isDriving: true, at: new Date(now - 60_000).toISOString() } };
    expect(suppressionReasons(user(), a, now)).toContain('driving');
    expect(suppressionReasons(user({ settings: { ...DEFAULT_SETTINGS, respectDriving: false } }), a, now)).not.toContain('driving');
  });
  it('stale or missing availability', () => {
    expect(suppressionReasons(user(), { busyBlocks: [], syncedAt: new Date(now - 49 * 3_600_000).toISOString() }, now)).toContain('stale');
    expect(suppressionReasons(user(), undefined, now)).toContain('no_availability');
  });
  it('busy with another nudge or call', () => {
    expect(suppressionReasons(user({ busyUntil: new Date(now + 60_000).toISOString() }), fresh, now)).toContain('busy_nudge');
    expect(suppressionReasons(user({ busyUntil: new Date(now - 60_000).toISOString() }), fresh, now)).not.toContain('busy_nudge');
    expect(suppressionReasons(user({ busyUntil: new Date(now + 60_000).toISOString() }), fresh, now, { ignoreBusy: true })).toEqual([]);
  });
  it('frequency', () => {
    expect(suppressionReasons(user({ settings: { ...DEFAULT_SETTINGS, frequency: 'off' } }), fresh, now)).toContain('frequency');
  });
});
