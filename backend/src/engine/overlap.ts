// Busy-block handling and mutual free-window computation.
import type { BusyBlock } from './types.js';

export interface Interval { start: number; end: number } // epoch ms

export const toInterval = (b: BusyBlock): Interval => ({ start: Date.parse(b.start), end: Date.parse(b.end) });

/** Sorts, drops invalid/empty blocks and merges overlapping or adjacent ones. */
export function mergeIntervals(blocks: Interval[]): Interval[] {
  const valid = blocks
    .filter((b) => Number.isFinite(b.start) && Number.isFinite(b.end) && b.end > b.start)
    .sort((a, b) => a.start - b.start);
  const out: Interval[] = [];
  for (const b of valid) {
    const last = out[out.length - 1];
    if (last && b.start <= last.end) last.end = Math.max(last.end, b.end);
    else out.push({ ...b });
  }
  return out;
}

export function mergeBusyBlocks(blocks: BusyBlock[]): BusyBlock[] {
  return mergeIntervals(blocks.map(toInterval)).map((i) => ({
    start: new Date(i.start).toISOString(),
    end: new Date(i.end).toISOString(),
  }));
}

/** Is `now` inside any busy block? */
export const isBusyAt = (blocks: Interval[], now: number) => blocks.some((b) => b.start <= now && now < b.end);

/** Start of the next busy block after `now`, or undefined. Assumes `now` is free. */
export function nextBusyStart(blocks: Interval[], now: number): number | undefined {
  let next: number | undefined;
  for (const b of blocks) if (b.start > now && (next === undefined || b.start < next)) next = b.start;
  return next;
}

/**
 * The mutual free window that starts now, capped at `horizonMin` minutes.
 * Returns null if either person is busy right now.
 */
export function mutualFreeWindow(
  now: number,
  a: BusyBlock[],
  b: BusyBlock[],
  horizonMin = 180,
): Interval | null {
  const ia = mergeIntervals(a.map(toInterval));
  const ib = mergeIntervals(b.map(toInterval));
  if (isBusyAt(ia, now) || isBusyAt(ib, now)) return null;
  const candidates = [now + horizonMin * 60_000, nextBusyStart(ia, now), nextBusyStart(ib, now)].filter(
    (x): x is number => x !== undefined,
  );
  return { start: now, end: Math.min(...candidates) };
}

/**
 * Free-now status for a single person, used by the Friends list. `busyUntil` is when the current busy stretch ends,
 * so the client knows when to look again for a new opening.
 */
export function freeStatus(now: number, blocks: BusyBlock[]): { freeNow: boolean; freeUntil?: string; busyUntil?: string } {
  const iv = mergeIntervals(blocks.map(toInterval));
  const busy = iv.find((b) => b.start <= now && now < b.end);
  if (busy) return { freeNow: false, busyUntil: new Date(busy.end).toISOString() };
  const next = nextBusyStart(iv, now);
  return { freeNow: true, freeUntil: next !== undefined ? new Date(next).toISOString() : undefined };
}
