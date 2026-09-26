import { describe, expect, it } from 'vitest';
import { deriveWhoopSignal } from '../src/engine/whoop.js';
import { suppressionReasons } from '../src/engine/suppression.js';
import { DEFAULT_SETTINGS } from '../src/engine/types.js';

const now = Date.parse('2026-09-26T12:00:00Z');
const nights = [23, 24, 25].map(day => ({ start: `2026-09-${day}T23:30:00Z`, end: `2026-09-${day + 1}T07:30:00Z` }));
describe('WHOOP availability estimates', () => {
  it('requires three recent main sleeps; ignores naps', () => {
    expect(deriveWhoopSignal(nights.slice(0, 2), [], 'UTC', now).sleepStart).toBeUndefined();
    expect(deriveWhoopSignal(nights.map(n => ({ ...n, nap: true })), [], 'UTC', now).sleepStart).toBeUndefined();
    expect(deriveWhoopSignal(nights, [], 'UTC', now)).toMatchObject({ sleepStart: '23:30', sleepEnd: '07:30' });
  });
  it('handles midnight without averaging bedtime into midday', () => {
    const mixed = [...nights.slice(0, 2), { start: '2026-09-26T00:30:00Z', end: '2026-09-26T08:30:00Z' }];
    expect(deriveWhoopSignal(mixed, [], 'UTC', now).sleepStart).toBe('23:30');
    expect(deriveWhoopSignal(nights, [], 'America/Chicago', now).sleepStart).toBe('18:30');
  });
  it('does not infer current sleep from old or malformed records', () => {
    expect(deriveWhoopSignal(nights, [], 'UTC', now + 3 * 86400000).sleepStart).toBeUndefined();
    expect(deriveWhoopSignal([{ start: 'bad', end: 'bad' }], [], 'UTC', now).sleepStart).toBeUndefined();
  });
  it('gives a buffer only for a recently ended workout', () => {
    const recent = { start: '2026-09-26T11:00:00Z', end: '2026-09-26T11:50:00Z' };
    expect(deriveWhoopSignal([], [recent], 'UTC', now).workoutUntil).toBe('2026-09-26T12:20:00.000Z');
    expect(deriveWhoopSignal([], [recent], 'UTC', now + 3600000).workoutUntil).toBeUndefined();
    expect(deriveWhoopSignal([], [recent], 'UTC', now, { sleepEnabled: true, workoutEnabled: false }).workoutUntil).toBeUndefined();
  });
  it('suppresses fresh estimates only and never treats stale WHOOP as busy', () => {
    const user = { id: 'u', tz: 'UTC', settings: { ...DEFAULT_SETTINGS, quietStart: '00:00', quietEnd: '00:00' } };
    const avail = { busyBlocks: [], syncedAt: new Date(now).toISOString(), whoop: {
      syncedAt: new Date(now).toISOString(), sleepStart: '11:00', sleepEnd: '13:00', workoutUntil: new Date(now + 1000).toISOString() } };
    expect(suppressionReasons(user, avail, now)).toEqual(expect.arrayContaining(['whoop_sleep', 'whoop_workout']));
    avail.whoop.syncedAt = new Date(now - 16 * 60000).toISOString();
    expect(suppressionReasons(user, avail, now)).not.toContain('whoop_sleep');
    expect(suppressionReasons(user, avail, now)).not.toContain('whoop_workout');
    avail.whoop.syncedAt = new Date(now + 60000).toISOString();
    expect(suppressionReasons(user, avail, now)).not.toContain('whoop_sleep');
  });
});
