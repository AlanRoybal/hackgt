// Tap phones to add a friend (ACC-13). Each phone holds a short-lived token from the server and hands it to
// the other over the local link. A tap records "I tapped them"; the friendship forms once both phones have
// recorded it, so one side replaying a token it overheard can't add anyone.

/** How long a phone's token can be redeemed. Phones fetch a new one well before this runs out. */
export const TAP_TOKEN_TTL_MS = 10 * 60_000;
/** How close together the two taps must land. */
export const TAP_INTENT_WINDOW_MS = 30_000;

export interface TapIntent {
  at: number;
  /** Set once this tap made the friendship, so the phone that tapped first still hears "friends". */
  matched?: boolean;
}

export type TapStep =
  | 'reject' //          blocked either way
  | 'added' //           friends because of this tap (the other phone got there first)
  | 'already_friends' // were friends before; do nothing
  | 'record'; //         write my tap, then look for theirs

export function tapStep(s: { blocked: boolean; friends: boolean; mine?: TapIntent; now: number }): TapStep {
  if (s.blocked) return 'reject';
  if (s.friends) return s.mine?.matched && s.now - s.mine.at < TAP_INTENT_WINDOW_MS ? 'added' : 'already_friends';
  return 'record';
}

export const isFreshTap = (intent: TapIntent | undefined, now: number) =>
  !!intent && now - intent.at >= 0 && now - intent.at < TAP_INTENT_WINDOW_MS;
