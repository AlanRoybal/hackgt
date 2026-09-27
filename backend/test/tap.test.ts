import { describe, expect, it } from 'vitest';
import { isFreshTap, TAP_INTENT_WINDOW_MS, tapStep } from '../src/engine/tap.js';

describe('tap to add (ACC-13)', () => {
  const now = 1_800_000_000_000;

  it('blocked either way rejects, even when a tap is recorded', () => {
    expect(tapStep({ blocked: true, friends: false, mine: { at: now }, now })).toBe('reject');
    expect(tapStep({ blocked: true, friends: true, now })).toBe('reject');
  });

  it('existing friends are left alone', () => {
    expect(tapStep({ blocked: false, friends: true, now })).toBe('already_friends');
    expect(tapStep({ blocked: false, friends: true, mine: { at: now - 1000 }, now })).toBe('already_friends');
  });

  it('the phone that tapped first hears "friends" once the other phone matches', () => {
    expect(tapStep({ blocked: false, friends: true, mine: { at: now - 1000, matched: true }, now })).toBe('added');
  });

  it('an old matched tap reads as already friends, not a new add', () => {
    expect(tapStep({ blocked: false, friends: true, mine: { at: now - TAP_INTENT_WINDOW_MS, matched: true }, now })).toBe('already_friends');
  });

  it('not yet friends records the tap', () => {
    expect(tapStep({ blocked: false, friends: false, now })).toBe('record');
    expect(tapStep({ blocked: false, friends: false, mine: { at: now - 5000 }, now })).toBe('record');
  });

  it('taps only pair up inside the window', () => {
    expect(isFreshTap(undefined, now)).toBe(false);
    expect(isFreshTap({ at: now - 1 }, now)).toBe(true);
    expect(isFreshTap({ at: now - TAP_INTENT_WINDOW_MS }, now)).toBe(false);
    expect(isFreshTap({ at: now + 5000 }, now)).toBe(false);
  });
});
