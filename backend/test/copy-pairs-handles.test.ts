import { describe, expect, it } from 'vitest';
import { directCopy, durationPhrase, nudgeCopy } from '../src/engine/copy.js';
import { isExpired, pickTopic, RESUGGEST_MS, TOPIC_EXPIRY_DAYS } from '../src/engine/topics.js';
import { checkHandle } from '../src/engine/handles.js';
import { choosePairs, rankPairs } from '../src/engine/pairChoice.js';

describe('nudge copy', () => {
  it('matches the product copy', () => {
    expect(nudgeCopy('Mom', 12).body).toBe('Your calendars look open for the next 10 minutes. Call?');
    expect(nudgeCopy('Mom', 17, 'the physics exam').body).toBe('Your calendars look open for 15 minutes. Want to follow up on the physics exam?');
    expect(nudgeCopy('Mom', 75).body).toBe('Your calendars look open for the next hour. Call?');
    expect(nudgeCopy('Mom', 60, 'the trip').body).toBe('Your calendars look open for the next hour. Want to follow up on the trip?');
    expect(nudgeCopy('Mom', 12).title).toBe('A moment to catch up with Mom?');
    expect(nudgeCopy('Mom', 10, "Dad's birthday").body).toBe("Your calendars look open for 10 minutes. Want to follow up on Dad's birthday?");
  });
  it('rounds down to 5 with a floor of 5', () => {
    expect(durationPhrase(9, true)).toBe('the next 5 minutes');
    expect(durationPhrase(5, false)).toBe('5 minutes');
    expect(durationPhrase(59, true)).toBe('the next 55 minutes');
  });
  it('direct call copy', () => {
    expect(directCopy('Alan', 'Mom').recipient.body).toBe('Alan wants to call. Free?');
    expect(directCopy('Mom', 'Alan', "Dad's birthday").recipient.body).toBe("Mom wants to call. Free to follow up on Dad's birthday?");
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

describe('topic choice', () => {
  const now = Date.parse('2026-09-26T15:00:00Z');
  const t = (id: string, followUpAfter: string | undefined, extra: Record<string, string> = {}) => ({ id, title: id, status: 'open', followUpAfter, ...extra });

  it('prefers the oldest due topic', () => {
    expect(pickTopic([t('later', '2026-09-30'), t('due', '2026-09-25'), t('today', '2026-09-26')], now)).toEqual({ id: 'due', title: 'due', due: true });
  });
  it('falls back to the nearest upcoming topic so alerts still have context', () => {
    expect(pickTopic([t('far', '2026-10-03'), t('near', '2026-09-29')], now)).toEqual({ id: 'near', title: 'near', due: false });
  });
  it('skips topics not worth a follow-up, used ones, and recent suggestions', () => {
    expect(pickTopic([t('none', undefined), t('used', '2026-09-20', { status: 'used' })], now)).toBeUndefined();
    const recent = new Date(now - 60_000).toISOString();
    expect(pickTopic([t('s', '2026-09-20', { status: 'suggested', suggestedAt: recent })], now)).toBeUndefined();
  });
  it('expires topics two weeks past their follow-up date', () => {
    expect(TOPIC_EXPIRY_DAYS).toBe(14);
    expect(isExpired({ followUpAfter: '2026-09-13' }, now)).toBe(false);
    expect(isExpired({ followUpAfter: '2026-09-12' }, now)).toBe(true);
    expect(pickTopic([t('stale', '2026-09-01'), t('fresh', '2026-09-20')], now)?.id).toBe('fresh');
    expect(pickTopic([t('stale', '2026-09-01')], now)).toBeUndefined();
  });
  it('offers a suggestion that never became a call again later', () => {
    const old = new Date(now - RESUGGEST_MS).toISOString();
    expect(pickTopic([t('s', '2026-09-20', { status: 'suggested', suggestedAt: old })], now)?.id).toBe('s');
  });
});
