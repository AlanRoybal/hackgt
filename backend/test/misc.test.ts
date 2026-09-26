import { describe, expect, it } from 'vitest';
import { extractJson } from '../src/ai/bedrock.js';
import { formatTranscript, retrievalQueries } from '../src/ai/detector.js';
import { parseRerank } from '../src/ai/rerank.js';
import { pairKey, segSk } from '../src/lib/keys.js';
import { validateSettingsPatch } from '../src/lib/settings.js';
import { dateRange, fusePhotoHits, isLikelyEcho, pickHit } from '../src/lib/references.js';
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

describe('retrieval query views', () => {
  it('keeps unique generated views and compatibility query', () => {
    expect(retrievalQueries({
      isReference: true,
      query: 'restaurant lanterns',
      literalQuery: 'lantern restaurant',
      visualQuery: 'restaurant with lanterns',
      entityQuery: 'lantern restaurant',
      confidence: 0.9,
    })).toEqual(['lantern restaurant', 'restaurant with lanterns', 'restaurant lanterns']);
  });
});

describe('photo reranker parsing', () => {
  const candidates = [{ key: 'u#one' }, { key: 'u#two' }];
  it('maps a one-based model choice back to a vector key', () => {
    expect(parseRerank('{"choice":2,"confidence":0.8}', candidates)).toEqual({ key: 'u#two', confidence: 0.8 });
  });
  it('accepts an explicit no-match and rejects invalid choices', () => {
    expect(parseRerank('{"choice":null,"confidence":0.9}', candidates)).toEqual({ confidence: 0 });
    expect(parseRerank('{"choice":3,"confidence":0.9}', candidates)).toBeUndefined();
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
  it('fuses image and caption ranks and applies a small place boost', () => {
    const image = [[
      { key: 'u#a', similarity: 0.5, metadata: { caption: 'plain cafe' } },
      { key: 'u#b', similarity: 0.49, metadata: { place: 'Atlanta cafe' } },
    ]];
    const caption = [[{ key: 'u#b', similarity: 0.42, metadata: { caption: 'lantern cafe', place: 'Atlanta cafe' } }]];
    expect(fusePhotoHits(image, caption, 'Atlanta').map((x) => x.key)).toEqual(['u#b', 'u#a']);
  });
  it('treats a line that repeats the friend as echo, even with transcription slips', () => {
    const friend = ['I made this huge bowl of ramen last night with a soft egg'];
    expect(isLikelyEcho('I made this huge bowl of ramen last night', friend)).toBe(true);
    expect(isLikelyEcho('made this huge bowl of rum in last night with soft egg', friend)).toBe(true);
  });
  it('keeps real replies and the speaker\'s own stories', () => {
    const friend = ['I made this huge bowl of ramen last night with a soft egg'];
    expect(isLikelyEcho('oh nice I had tacos at that new place downtown', friend)).toBe(false);
    expect(isLikelyEcho('ramen sounds amazing, we went hiking at Stone Mountain', friend)).toBe(false);
    expect(isLikelyEcho('I made this huge bowl of ramen', [])).toBe(false);
    expect(isLikelyEcho('ramen ramen', friend)).toBe(false);
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
