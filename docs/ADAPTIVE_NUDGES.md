# Adaptive nudge timing

Automatic invitations now adapt to responses without changing the frequency chosen in Settings.
An empty calendar means no known conflict, not proof that someone is free.

## Behavior

- A skip contributes 1 point of interruption pressure; an unanswered invitation contributes 0.35.
- Pressure halves every two days. Accepting subtracts 2 points, with a floor of zero.
- At 1.5 points, a negative response starts a temporary cooldown of 6 hours per point, capped at 24 hours. Its end is fixed to that response; scheduler runs do not extend it.
- The one-hour pause action skips the invitation and suppresses automatic nudges from every friend for an hour. Existing frequency limits or learned backoff can last longer.
- Long-term preferences use three-hour local-time windows, at least three distinct observation days, and a seven-day weight half-life. A sufficiently unfavorable window defers attempts only during its first hour. The remaining two hours permit exploration, subject to all normal protections.
- When choosing among eligible pairs, due topics remain first, followed by the weaker of the two people's timing preferences, then time since their last call.
- Only automatic invitations teach timing. Direct calls do not imply willingness to receive unsolicited nudges. A manual pause on a direct invitation still pauses automatic nudges.
- Calendar, Focus, driving, WHOOP, quiet hours, frequency limits and pair cooldowns still apply. Acceptance never overrides a manual pause or these checks.

The engine considers up to 100 responses from the last 28 days. Older samples are ignored immediately and removed from the bounded profile history on the next response. Account deletion removes this history. Samples contain invitation ID, offered/response timestamps and outcome; no location or transcript is needed. The private history is not included in public user DTOs.

Responses and history updates commit atomically in DynamoDB, guarded by nudge and history versions. Expiry records only people who did not respond; it does not penalize someone whose friend declined. Duplicate transitions cannot record a second sample.

“See this less often” remains an explicit, lasting frequency choice, with Undo. Its double-reduction bug is fixed in the new client.

## Quick demo

From `backend`:

```sh
npm run demo:adaptive
```

This advances a synthetic clock through a busy week and recovery using the same engine as the matcher. It makes no AWS requests and sends no notifications. The table demonstrates: new user → repeated skips → temporary backoff → automatic recovery → acceptance. Clearly label this as a simulated timeline in the presentation, rather than a live week of user behavior.

Suggested narration: “A clear calendar isn't a promise that you're free. Nudge backs off when invitations aren't welcome, then cautiously tries again as those signals age. A busy week doesn't become a permanent rule.”

On a rebuilt phone, the automatic invitation banner has “Not now · pause for an hour”; the long-press menu also offers the pause. Nudge settings explain adaptation. New behavior needs real response history; it does not retroactively infer past availability.

## Validation and limitations

Tests cover cold start, missed-versus-skipped weighting, busy-week recovery without feedback, acceptance, timing exploration, timezone handling, expiry attribution, transactional conflicts, and preserving hard protections. A synthetic DynamoDB concurrency probe verifies one committed sample and pause when two transitions race.

These initial weights are heuristics, not a trained or empirically validated prediction model. Notification expiry is weak evidence because delivery/opening isn't confirmed. Time preferences do not infer why someone declined or whether they dislike a particular friend. There is no location learning or claim of exact availability. Evaluate acceptance rate and unwanted interruptions before tuning weights.
