import fc from 'fast-check';
import { describe, expect, it } from 'vitest';
import { LEVELS, pairAllows, stepDown, stricter, userAllows } from '../src/engine/frequency.js';
import { becameBusyAt } from '../src/engine/overlap.js';
import { isTerminal, transition, type MachineNudge, type NudgeEvent } from '../src/engine/state.js';
import type { Frequency } from '../src/engine/types.js';

const H = 3_600_000;
const now = Date.parse('2026-09-26T18:00:00Z');
const ago = (ms: number) => new Date(now - ms).toISOString();

describe('frequency', () => {
  it('stepDown floors at low and keeps off', () => {
    expect(stepDown('high')).toBe('normal');
    expect(stepDown('normal')).toBe('low');
    expect(stepDown('low')).toBe('low');
    expect(stepDown('off')).toBe('off');
  });

  it('daily cap per level', () => {
    expect(userAllows('normal', [ago(10 * H), ago(8 * H), ago(5 * H)], ago(5 * H), now)).toBe(false);
    expect(userAllows('normal', [ago(25 * H), ago(8 * H), ago(5 * H)], ago(5 * H), now)).toBe(true);
    expect(userAllows('low', [ago(23 * H)], ago(23 * H), now)).toBe(false);
    expect(userAllows('off', [], undefined, now)).toBe(false);
  });

  it('minimum gap between nudges', () => {
    expect(userAllows('high', [], ago(30 * 60_000), now)).toBe(false);
    expect(userAllows('high', [], ago(50 * 60_000), now)).toBe(true);
    expect(userAllows('normal', [], ago(1.5 * H), now)).toBe(false);
  });

  it('pair cooldown uses the stricter level and the later of nudge/call', () => {
    expect(pairAllows('high', 'high', ago(9 * H), undefined, now)).toBe(true);
    expect(pairAllows('high', 'normal', ago(9 * H), undefined, now)).toBe(false);
    expect(pairAllows('normal', 'normal', ago(30 * H), ago(2 * H), now)).toBe(false);
    expect(pairAllows('normal', 'normal', undefined, undefined, now)).toBe(true);
    expect(pairAllows('off', 'high', undefined, undefined, now)).toBe(false);
  });

  it('becoming busy after the last nudge or call resets the limits', () => {
    const busy = now - 30 * 60_000; // an event started 30 min ago and has since ended
    expect(pairAllows('normal', 'normal', ago(2 * H), ago(1 * H), now, busy)).toBe(true);
    expect(userAllows('normal', [ago(10 * H), ago(8 * H), ago(1 * H)], ago(1 * H), now, busy)).toBe(true);
    // Contact after the user became busy (the free period since then) still counts.
    expect(pairAllows('normal', 'normal', ago(10 * 60_000), undefined, now, busy)).toBe(false);
    expect(userAllows('normal', [], ago(10 * 60_000), now, busy)).toBe(false);
    expect(pairAllows('off', 'normal', undefined, undefined, now, busy)).toBe(false);
  });

  it('becameBusyAt remembers the latest block that has started', () => {
    const blocks = [
      { start: ago(3 * H), end: ago(2 * H) },
      { start: ago(1 * H), end: ago(30 * 60_000) },
      { start: new Date(now + H).toISOString(), end: new Date(now + 2 * H).toISOString() },
    ];
    expect(becameBusyAt({ busyBlocks: blocks }, now)).toBe(now - H);
    expect(becameBusyAt({ busyBlocks: [], lastBusyStart: ago(H) }, now)).toBe(now - H);
    expect(becameBusyAt({ busyBlocks: blocks.slice(2) }, now)).toBeUndefined();
    expect(becameBusyAt(undefined, now)).toBeUndefined();
  });

  it('property: never more than dailyCap nudges in any 24 h window when the limiter is obeyed', () => {
    const levels: Frequency[] = ['low', 'normal', 'high'];
    fc.assert(
      fc.property(fc.constantFrom(...levels), fc.array(fc.integer({ min: 1, max: 600 }), { minLength: 1, maxLength: 200 }), (level, gaps) => {
        let t = now;
        const sent: number[] = [];
        for (const g of gaps) {
          t += g * 60_000;
          const recent = sent.map((s) => new Date(s).toISOString());
          const last = sent.length ? new Date(sent[sent.length - 1]).toISOString() : undefined;
          if (userAllows(level, recent, last, t)) sent.push(t);
        }
        for (const s of sent) {
          const inWindow = sent.filter((x) => x >= s && x < s + 24 * H).length;
          expect(inWindow).toBeLessThanOrEqual(LEVELS[level].dailyCap);
        }
      }),
    );
  });

  it('stricter', () => {
    expect(stricter('high', 'low')).toBe('low');
    expect(stricter('normal', 'off')).toBe('off');
  });
});

describe('nudge state machine', () => {
  const base = (over: Partial<MachineNudge> = {}): MachineNudge => ({ state: 'pending', participants: ['a', 'b'], responses: {}, ...over });

  it('accept, accept → matched with create_call', () => {
    const t1 = transition(base(), { type: 'respond', userId: 'a', action: 'accept' });
    expect(t1.next.state).toBe('accepted_by_one');
    const t2 = transition(t1.next, { type: 'respond', userId: 'b', action: 'accept' });
    expect(t2.next.state).toBe('matched');
    expect(t2.effects).toEqual([{ type: 'create_call' }]);
  });

  it('accept then skip → skipped with follow-up from skipper to accepter', () => {
    const t1 = transition(base(), { type: 'respond', userId: 'a', action: 'accept' });
    const t2 = transition(t1.next, { type: 'respond', userId: 'b', action: 'skip' });
    expect(t2.next.state).toBe('skipped');
    expect(t2.effects).toContainEqual({ type: 'follow_up', fromUserId: 'b', toUserId: 'a' });
  });

  it('skip with no acceptance → no follow-up', () => {
    const t = transition(base(), { type: 'respond', userId: 'a', action: 'skip' });
    expect(t.next.state).toBe('skipped');
    expect(t.effects.find((e) => e.type === 'follow_up')).toBeUndefined();
  });

  it('less = skip + step down', () => {
    const t = transition(base(), { type: 'respond', userId: 'b', action: 'less' });
    expect(t.next.responses.b).toBe('less');
    expect(t.effects).toContainEqual({ type: 'step_down_frequency', userId: 'b' });
  });

  it('expiry after one acceptance counts as a skip', () => {
    const t = transition(base({ state: 'accepted_by_one', responses: { a: 'accepted' } }), { type: 'expire' });
    expect(t.next.state).toBe('expired');
    expect(t.next.responses.b).toBe('expired');
    expect(t.effects).toContainEqual({ type: 'follow_up', fromUserId: 'b', toUserId: 'a' });
  });

  it('rejects responses from non-participants and double responses', () => {
    expect(transition(base(), { type: 'respond', userId: 'z', action: 'accept' }).ok).toBe(false);
    const t1 = transition(base(), { type: 'respond', userId: 'a', action: 'accept' });
    expect(transition(t1.next, { type: 'respond', userId: 'a', action: 'skip' }).ok).toBe(false);
  });

  it('precheck → pending, precheck failure → cancelled; matched → in_call → ended', () => {
    expect(transition(base({ state: 'precheck' }), { type: 'sent' }).next.state).toBe('pending');
    expect(transition(base({ state: 'precheck' }), { type: 'precheck_failed' }).next.state).toBe('cancelled');
    expect(transition(base({ state: 'matched' }), { type: 'join' }).next.state).toBe('in_call');
    expect(transition(base({ state: 'in_call' }), { type: 'end' }).next.state).toBe('ended');
  });

  it('property: terminal states never change, and every transition keeps participants', () => {
    const ev: fc.Arbitrary<NudgeEvent> = fc.oneof(
      fc.constant({ type: 'sent' } as NudgeEvent),
      fc.constant({ type: 'precheck_failed' } as NudgeEvent),
      fc.constant({ type: 'expire' } as NudgeEvent),
      fc.constant({ type: 'join' } as NudgeEvent),
      fc.constant({ type: 'end' } as NudgeEvent),
      fc.record({ type: fc.constant('cancel' as const), userId: fc.constantFrom('a', 'b', 'z') }),
      fc.record({ type: fc.constant('respond' as const), userId: fc.constantFrom('a', 'b', 'z'), action: fc.constantFrom('accept' as const, 'skip' as const, 'less' as const) }),
    );
    fc.assert(
      fc.property(fc.array(ev, { maxLength: 20 }), (events) => {
        let n = base({ state: 'precheck' });
        for (const e of events) {
          const wasTerminal = isTerminal(n.state);
          const t = transition(n, e);
          if (wasTerminal) expect(t.ok).toBe(false);
          expect(t.next.participants).toEqual(['a', 'b']);
          if (t.next.state === 'matched') expect(Object.values(t.next.responses).filter((r) => r === 'accepted').length).toBe(2);
          n = t.next;
        }
      }),
    );
  });
});
