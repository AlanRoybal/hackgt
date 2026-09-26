import fc from 'fast-check';
import { describe, expect, it } from 'vitest';
import { freeStatus, isBusyAt, mergeBusyBlocks, mergeIntervals, mutualFreeWindow } from '../src/engine/overlap.js';

const T = (s: string) => Date.parse(s);
const b = (start: string, end: string) => ({ start, end });

describe('mergeIntervals', () => {
  it('merges overlapping and adjacent blocks and drops invalid ones', () => {
    const merged = mergeIntervals([
      { start: 10, end: 20 },
      { start: 20, end: 30 },
      { start: 25, end: 26 },
      { start: 40, end: 50 },
      { start: 60, end: 55 },
      { start: NaN, end: 70 },
    ]);
    expect(merged).toEqual([
      { start: 10, end: 30 },
      { start: 40, end: 50 },
    ]);
  });

  it('property: merged output is sorted, disjoint, and covers exactly the same instants', () => {
    const iv = fc.tuple(fc.integer({ min: 0, max: 200 }), fc.integer({ min: 1, max: 50 })).map(([s, l]) => ({ start: s, end: s + l }));
    fc.assert(
      fc.property(fc.array(iv, { maxLength: 30 }), fc.integer({ min: -5, max: 260 }), (blocks, probe) => {
        const m = mergeIntervals(blocks);
        for (let i = 1; i < m.length; i++) expect(m[i].start).toBeGreaterThan(m[i - 1].end);
        expect(isBusyAt(m, probe)).toBe(isBusyAt(blocks, probe));
      }),
    );
  });
});

describe('mutualFreeWindow', () => {
  const now = T('2026-09-26T15:00:00Z');

  it('returns null if either person is busy now', () => {
    expect(mutualFreeWindow(now, [b('2026-09-26T14:30:00Z', '2026-09-26T15:30:00Z')], [])).toBeNull();
    expect(mutualFreeWindow(now, [], [b('2026-09-26T15:00:00Z', '2026-09-26T15:10:00Z')])).toBeNull();
  });

  it('ends at the earliest next busy block of either person', () => {
    const w = mutualFreeWindow(now, [b('2026-09-26T15:40:00Z', '2026-09-26T16:00:00Z')], [b('2026-09-26T15:12:00Z', '2026-09-26T15:20:00Z')]);
    expect(w).toEqual({ start: now, end: T('2026-09-26T15:12:00Z') });
  });

  it('a block ending exactly now is not busy (half-open intervals)', () => {
    const w = mutualFreeWindow(now, [b('2026-09-26T14:00:00Z', '2026-09-26T15:00:00Z')], []);
    expect(w?.start).toBe(now);
  });

  it('caps at the horizon when nobody has anything coming up', () => {
    expect(mutualFreeWindow(now, [], [], 180)?.end).toBe(now + 180 * 60_000);
  });

  it('property: the window never overlaps any busy block', () => {
    const blockArb = fc
      .tuple(fc.integer({ min: -120, max: 400 }), fc.integer({ min: 1, max: 120 }))
      .map(([s, l]) => b(new Date(now + s * 60_000).toISOString(), new Date(now + (s + l) * 60_000).toISOString()));
    fc.assert(
      fc.property(fc.array(blockArb, { maxLength: 10 }), fc.array(blockArb, { maxLength: 10 }), (a, c) => {
        const w = mutualFreeWindow(now, a, c);
        if (!w) return;
        for (const blk of [...a, ...c]) {
          const s = T(blk.start);
          const e = T(blk.end);
          expect(e <= w.start || s >= w.end).toBe(true);
        }
      }),
    );
  });
});

describe('mergeBusyBlocks / freeStatus', () => {
  it('round-trips ISO strings', () => {
    expect(mergeBusyBlocks([b('2026-09-26T10:00:00.000Z', '2026-09-26T11:00:00.000Z'), b('2026-09-26T10:30:00.000Z', '2026-09-26T12:00:00.000Z')])).toEqual([
      b('2026-09-26T10:00:00.000Z', '2026-09-26T12:00:00.000Z'),
    ]);
  });
  it('reports free until the next block', () => {
    const now = T('2026-09-26T09:00:00Z');
    expect(freeStatus(now, [b('2026-09-26T10:00:00Z', '2026-09-26T11:00:00Z')])).toEqual({ freeNow: true, freeUntil: '2026-09-26T10:00:00.000Z' });
    expect(freeStatus(T('2026-09-26T10:30:00Z'), [b('2026-09-26T10:00:00Z', '2026-09-26T11:00:00Z')])).toEqual({ freeNow: false, busyUntil: '2026-09-26T11:00:00.000Z' });
  });
});
