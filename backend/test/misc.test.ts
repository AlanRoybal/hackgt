import { describe, expect, it } from 'vitest';
import { extractJson } from '../src/ai/bedrock.js';
import { formatTranscript } from '../src/ai/detector.js';
import { pairKey, segSk } from '../src/lib/keys.js';
import { validateSettingsPatch } from '../src/lib/settings.js';
import { dateRange, pickHit } from '../src/lib/references.js';
import { cutoffSec } from '../src/handlers/photoSweep.js';
import { payloads } from '../src/lib/push.js';

describe('keys', () => {
  it('pairKey is order independent', () => expect(pairKey('b', 'a')).toBe(pairKey('a', 'b')));
  it('segment sort keys order by time', () => {
    expect(segSk(9, 'u', 's') < segSk(10, 'u', 's')).toBe(true);
    expect(segSk(1727000000000, 'u', 's')).toBe('SEG#1727000000000#u#s');
  });
});

describe('extractJson', () => {
  it('handles fences, chatter and nested braces', () => {
    expect(extractJson('Sure!\n```json\n{"a":{"b":"}"},"c":1}\n```')).toEqual({ a: { b: '}' }, c: 1 });
    expect(extractJson('nothing here')).toBeUndefined();
  });
});

describe('detector transcript formatting', () => {
  it('labels the speaker and friend', () => {
    expect(formatTranscript([{ userId: 'a', text: 'hi' }, { userId: 'b', text: 'yo' }], 'b')).toBe('FRIEND: hi\nSPEAKER: yo');
  });
});

describe('settings validation', () => {
  it('accepts valid and ignores client-only keys', () => {
    expect(validateSettingsPatch({ frequency: 'high', disabledCalendarIds: ['x'], minWindowMin: 15 })).toEqual({ frequency: 'high', minWindowMin: 15 });
  });
  it.each([{ frequency: 'sometimes' }, { quietStart: '25:00' }, { minWindowMin: 7 }, { photoMode: 'maybe' }])('rejects %o', (p) => {
    expect(() => validateSettingsPatch(p)).toThrow();
  });
});

describe('reference helpers', () => {
  it('dateRange adds a day of slack', () => {
    const r = dateRange({ from: '2026-09-19', to: '2026-09-20' });
    expect(r.fromSec).toBe(Date.parse('2026-09-18T00:00:00Z') / 1000);
    expect(r.toSec).toBe(Date.parse('2026-09-21T23:59:59Z') / 1000);
    expect(dateRange(undefined)).toEqual({});
  });
  it('pickHit respects threshold and skips already-suggested photos', () => {
    const hits = [
      { key: 'u#1', similarity: 0.4, metadata: {} },
      { key: 'u#2', similarity: 0.35, metadata: {} },
      { key: 'u#3', similarity: 0.1, metadata: {} },
    ];
    expect(pickHit(hits, 0.2, new Set())?.key).toBe('u#1');
    expect(pickHit(hits, 0.2, new Set(['u#1']))?.key).toBe('u#2');
    expect(pickHit(hits, 0.5, new Set())).toBeUndefined();
  });
});

describe('sweep cutoff', () => {
  it('is 30 days before now', () => {
    const now = Date.parse('2026-09-26T00:00:00Z');
    expect(cutoffSec(now)).toBe(Date.parse('2026-08-27T00:00:00Z') / 1000);
  });
});

describe('APNs payloads (SPEC §3.9)', () => {
  it('nudge alert', () => {
    const p = payloads.nudge({ title: 't', body: 'b', nudgeId: 'n', friendId: 'f', friendName: 'Mom', windowStart: 's', windowEnd: 'e', minutes: 10 });
    expect(p.aps.category).toBe('NUDGE');
    expect(p.aps['mutable-content']).toBe(1);
    expect(p.type).toBe('nudge');
  });
  it('voip and background', () => {
    expect(payloads.voip({ callId: 'c', nudgeId: 'n', callerId: 'u', callerName: 'Mom' })).toMatchObject({ type: 'call.incoming', hasVideo: true });
    expect(payloads.background('nudge.cleanup', 'n')).toEqual({ aps: { 'content-available': 1 }, type: 'nudge.cleanup', nudgeId: 'n' });
  });
});
