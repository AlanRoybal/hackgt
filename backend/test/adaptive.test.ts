import { describe, expect, it } from 'vitest';
import { adaptiveDecision, appendResponse, HOUR, type AdaptiveHistory, type ResponseSample } from '../src/engine/adaptive.js';
import { suppressionReasons } from '../src/engine/suppression.js';
import { DEFAULT_SETTINGS } from '../src/engine/types.js';
import { transition } from '../src/engine/state.js';
const now = Date.parse('2026-09-26T18:00:00Z');
const sample = (hoursAgo: number, outcome: ResponseSample['outcome'], id = String(hoursAgo)): ResponseSample => ({ id, outcome, at: new Date(now - hoursAgo * HOUR).toISOString(), offeredAt: new Date(now - hoursAgo * HOUR).toISOString() });
const decide = (samples: ResponseSample[], at = now) => adaptiveDecision({ samples }, 'UTC', at);
describe('adaptive timing', () => {
  it('does not penalize a new user or one decline', () => {
    expect(decide([]).cooldownUntil).toBe(0);
    expect(decide([sample(0, 'skip')]).cooldownUntil).toBe(0);
  });
  it('backs off for repeated skips but gives missed notifications less weight', () => {
    expect(decide([sample(3, 'skip'), sample(0, 'skip')]).cooldownUntil).toBeGreaterThan(now);
    expect(decide([sample(3, 'expired'), sample(0, 'expired')]).cooldownUntil).toBe(0);
  });
  it('automatically recovers after a busy week without requiring acceptance', () => {
    const history = Array.from({ length: 7 }, (_, i) => sample(i * 24, 'skip'));
    expect(decide(history).cooldownUntil).toBeGreaterThan(now);
    expect(decide(history, now + 25 * HOUR).cooldownUntil).toBeLessThan(now + 25 * HOUR);
    expect(decide(history, now + 7 * 24 * HOUR).pressure).toBeLessThan(0.5);
    expect(decide(history, now + 29 * 24 * HOUR).preference).toBe(0);
  });
  it('acceptance eases backoff without changing frequency or overriding explicit pause', () => {
    const history = [sample(3, 'skip'), sample(1, 'skip'), sample(0, 'accept')];
    expect(decide(history).cooldownUntil).toBe(0);
    const user = { id: 'a', tz: 'UTC', settings: { ...DEFAULT_SETTINGS }, adaptive: { samples: history }, nudgePausedUntil: new Date(now + HOUR).toISOString() };
    expect(suppressionReasons(user, { busyBlocks: [], syncedAt: new Date(now).toISOString() }, now)).toContain('paused');
    expect(user.settings.frequency).toBe('normal');
  });
  it('learns across days, only defers one hour, and allows exploration afterward', () => {
    const history = [sample(48, 'skip'), sample(72, 'skip'), sample(96, 'skip')];
    expect(decide(history).timingDeferred).toBe(true);
    expect(decide(history, now + HOUR).timingDeferred).toBe(false);
    expect(decide([sample(0, 'skip'), sample(0.1, 'skip'), sample(0.2, 'skip')]).timingDeferred).toBe(false);
    expect(adaptiveDecision({ samples: history }, 'America/New_York', now).timingDeferred).toBe(false);
  });
  it('ignores future and invalid data; prunes old records and deduplicates retries', () => {
    expect(decide([sample(-1, 'skip'), { ...sample(0, 'skip'), at: 'invalid' }]).pressure).toBe(0);
    let history: AdaptiveHistory = { samples: [sample(29 * 24, 'skip')] };
    history = appendResponse(history, sample(0, 'accept', 'same'), now);
    history = appendResponse(history, sample(0, 'accept', 'same'), now);
    expect(history.samples).toHaveLength(1);
  });
  it('retains all hard availability and frequency protections', () => {
    const u = { id: 'a', tz: 'UTC', settings: { ...DEFAULT_SETTINGS, frequency: 'off' as const }, adaptive: { samples: [sample(0, 'accept')] } };
    const reasons = suppressionReasons(u, { busyBlocks: [], syncedAt: new Date(now).toISOString(), focus: { isFocused: true, at: new Date(now).toISOString() } }, now);
    expect(reasons).toContain('focus'); expect(reasons).toContain('frequency');
  });
  it('pause declines the invitation without permanently lowering frequency', () => {
    const result = transition({ state: 'pending', participants: ['a', 'b'], responses: {} }, { type: 'respond', userId: 'a', action: 'pause' });
    expect(result.next.responses.a).toBe('skipped');
    expect(result.effects.some(e => e.type === 'step_down_frequency')).toBe(false);
  });
});
