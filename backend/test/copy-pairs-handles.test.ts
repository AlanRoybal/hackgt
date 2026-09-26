import { describe, expect, it } from 'vitest';
import { directCopy, durationPhrase, nudgeCopy } from '../src/engine/copy.js';
import { checkHandle } from '../src/engine/handles.js';
import { choosePairs, rankPairs } from '../src/engine/pairChoice.js';

describe('nudge copy', () => {
  it('matches the product copy', () => {
    expect(nudgeCopy('Mom', 12).body).toBe('You and Mom are both free for the next 10 minutes. Call?');
    expect(nudgeCopy('Mom', 17, 'the physics exam').body).toBe('You and Mom are both free for 15 minutes. Want to follow up about the physics exam?');
    expect(nudgeCopy('Mom', 75).body).toBe('You and Mom are both free for the next hour. Call?');
    expect(nudgeCopy('Mom', 60, 'the trip').body).toBe('You and Mom are both free for the next hour. Want to follow up about the trip?');
    expect(nudgeCopy('Mom', 12).title).toBe('Mom is free too');
  });
  it('rounds down to 5 with a floor of 5', () => {
    expect(durationPhrase(9, true)).toBe('the next 5 minutes');
    expect(durationPhrase(5, false)).toBe('5 minutes');
    expect(durationPhrase(59, true)).toBe('the next 55 minutes');
  });
  it('direct call copy', () => {
    expect(directCopy('Alan', 'Mom').recipient.body).toBe('Alan wants to call. Free?');
  });
});

describe('pair choice', () => {
  it('prefers a due topic, then the longest time since the last call (never called first)', () => {
    const ranked = rankPairs([
      { pairKey: 'p1', a: 'a', b: 'b', hasDueTopic: false, lastCallAt: '2026-09-01T00:00:00Z' },
      { pairKey: 'p2', a: 'c', b: 'd', hasDueTopic: false },
      { pairKey: 'p3', a: 'e', b: 'f', hasDueTopic: true, lastCallAt: '2026-09-25T00:00:00Z' },
      { pairKey: 'p4', a: 'g', b: 'h', hasDueTopic: false, lastCallAt: '2026-08-01T00:00:00Z' },
    ]);
    expect(ranked.map((p) => p.pairKey)).toEqual(['p3', 'p2', 'p4', 'p1']);
  });
  it('gives each user at most one nudge per run', () => {
    const chosen = choosePairs([
      { pairKey: 'ab', a: 'a', b: 'b', hasDueTopic: true },
      { pairKey: 'ac', a: 'a', b: 'c', hasDueTopic: false },
      { pairKey: 'cd', a: 'c', b: 'd', hasDueTopic: false },
    ]);
    expect(chosen.map((p) => p.pairKey)).toEqual(['ab', 'cd']);
  });
});

describe('handles', () => {
  it.each([
    ['alan', true],
    ['Alan_R', true],
    ['@mom.2', true],
    ['ab', false],
    ['a'.repeat(21), false],
    ['.alan', false],
    ['alan.', false],
    ['al..an', false],
    ['al an', false],
    ['alán', false],
  ])('%s → %s', (h, ok) => expect(checkHandle(h).ok).toBe(ok));
  it('lowercases and strips @', () => {
    expect(checkHandle('@Alan_R')).toEqual({ ok: true, handle: 'alan_r' });
  });
  it('blocks reserved words', () => {
    expect(checkHandle('admin')).toEqual({ ok: false, reason: 'reserved' });
    expect(checkHandle('Support')).toEqual({ ok: false, reason: 'reserved' });
  });
});
