// /nudges/* (SPEC NUD-9..12).
import { activeNudgeFor, applyEvent, getNudge, nudgeDTO, resolveFollowUp } from '../lib/flows.js';
import { bad, notFound, router } from '../lib/http.js';
import { getUser } from '../lib/users.js';

async function participantNudge(id: string, userId: string) {
  const n = await getNudge(id);
  if (!n.participants.includes(userId)) throw notFound('nudge_not_found');
  return n;
}

export const handler = router({
  'GET /nudges/active': async ({ userId }) => {
    const n = await activeNudgeFor(await getUser(userId));
    return { nudge: n ? await nudgeDTO(n, userId) : null };
  },

  'GET /nudges/{id}': async ({ userId, params }) => nudgeDTO(await participantNudge(params.id, userId), userId),

  'POST /nudges/{id}/respond': async ({ userId, params, body }) => {
    if (!['accept', 'skip', 'less'].includes(body.action)) throw bad('invalid_action');
    await participantNudge(params.id, userId);
    const n = await applyEvent(params.id, { type: 'respond', userId, action: body.action });
    return nudgeDTO(n, userId);
  },

  'POST /nudges/{id}/followup': async ({ userId, params, body }) => {
    if (!['send', 'discard'].includes(body.action)) throw bad('invalid_action');
    if (body.body !== undefined && typeof body.body !== 'string') throw bad('invalid_body');
    await participantNudge(params.id, userId);
    return nudgeDTO(await resolveFollowUp(params.id, userId, body.action, body.body), userId);
  },

  'POST /nudges/{id}/cancel': async ({ userId, params }) => {
    await participantNudge(params.id, userId);
    const n = await applyEvent(params.id, { type: 'cancel', userId });
    return nudgeDTO(n, userId);
  },
});
