// Nudge state machine (SPEC NUD-10). Pure: returns the next state plus side effects to run.
import { TERMINAL_STATES, type NudgeResponse, type NudgeState } from './types.js';

export interface MachineNudge {
  state: NudgeState;
  participants: [string, string];
  responses: Record<string, NudgeResponse | undefined>;
}

export type NudgeEvent =
  | { type: 'sent' }
  | { type: 'precheck_failed' }
  | { type: 'respond'; userId: string; action: 'accept' | 'skip' | 'less' }
  | { type: 'expire' }
  | { type: 'cancel'; userId: string }
  | { type: 'join' }
  | { type: 'end' };

export type Effect =
  | { type: 'create_call' }
  | { type: 'follow_up'; fromUserId: string; toUserId: string }
  | { type: 'step_down_frequency'; userId: string }
  | { type: 'cleanup' } // remove notifications, release reservations
  | { type: 'missed_event' };

export interface Transition {
  ok: boolean;
  error?: string;
  next: MachineNudge;
  effects: Effect[];
}

const other = (n: MachineNudge, id: string) => (n.participants[0] === id ? n.participants[1] : n.participants[0]);

export const isTerminal = (s: NudgeState) => TERMINAL_STATES.includes(s);

export function transition(n: MachineNudge, e: NudgeEvent): Transition {
  const fail = (error: string): Transition => ({ ok: false, error, next: n, effects: [] });
  const go = (state: NudgeState, responses = n.responses, effects: Effect[] = []): Transition => ({
    ok: true,
    next: { ...n, state, responses },
    effects,
  });

  switch (e.type) {
    case 'sent':
      return n.state === 'precheck' ? go('pending') : fail('invalid_state');
    case 'precheck_failed':
      return n.state === 'precheck' ? go('cancelled', n.responses, [{ type: 'cleanup' }]) : fail('invalid_state');
    case 'respond': {
      if (!n.participants.includes(e.userId)) return fail('not_participant');
      if (n.state !== 'pending' && n.state !== 'accepted_by_one') return fail('invalid_state');
      if (n.responses[e.userId]) return fail('already_responded');
      const them = other(n, e.userId);
      if (e.action === 'accept') {
        const responses = { ...n.responses, [e.userId]: 'accepted' as const };
        if (n.responses[them] === 'accepted') return go('matched', responses, [{ type: 'create_call' }]);
        return go('accepted_by_one', responses);
      }
      const responses = { ...n.responses, [e.userId]: (e.action === 'less' ? 'less' : 'skipped') as NudgeResponse };
      const effects: Effect[] = [{ type: 'cleanup' }, { type: 'missed_event' }];
      if (e.action === 'less') effects.push({ type: 'step_down_frequency', userId: e.userId });
      if (n.responses[them] === 'accepted') effects.push({ type: 'follow_up', fromUserId: e.userId, toUserId: them });
      return go('skipped', responses, effects);
    }
    case 'expire': {
      if (n.state !== 'pending' && n.state !== 'accepted_by_one') return fail('invalid_state');
      const responses = { ...n.responses };
      const effects: Effect[] = [{ type: 'cleanup' }, { type: 'missed_event' }];
      for (const p of n.participants) if (!responses[p]) responses[p] = 'expired';
      // Expiring counts as skipping: the non-responder "skipped" the one who accepted.
      const accepter = n.participants.find((p) => n.responses[p] === 'accepted');
      if (accepter) effects.push({ type: 'follow_up', fromUserId: other(n, accepter), toUserId: accepter });
      return go('expired', responses, effects);
    }
    case 'cancel':
      if (!n.participants.includes(e.userId)) return fail('not_participant');
      if (n.state !== 'accepted_by_one' && n.state !== 'pending') return fail('invalid_state');
      return go('cancelled', n.responses, [{ type: 'cleanup' }]);
    case 'join':
      if (n.state === 'in_call') return go('in_call');
      return n.state === 'matched' ? go('in_call') : fail('invalid_state');
    case 'end':
      return n.state === 'matched' || n.state === 'in_call' ? go('ended') : fail('invalid_state');
  }
}
