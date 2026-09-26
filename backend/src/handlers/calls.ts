// /calls/* — join, end, summary, photo shares (SPEC CALL, REF-7, REF-11, D-6).
import { get, put, update } from '../lib/db.js';
import { applyEvent, endCall, getCall, otherOf, topicDTO, type CallItem } from '../lib/flows.js';
import { bad, forbidden, HttpError, notFound, Res, router } from '../lib/http.js';
import { K, newId } from '../lib/keys.js';
import { presignGet } from '../lib/s3.js';
import { getFriendship, getUser, publicUser } from '../lib/users.js';
import { queryPrefix } from '../lib/db.js';

const SHARE_URL_TTL_S = 300;
/** The post-call recap can list the call's photos for this long after it ends (D-6 amendment). */
const RECAP_WINDOW_MS = 60 * 60 * 1000;

async function participantCall(id: string, userId: string): Promise<CallItem> {
  const c = await getCall(id);
  if (!c.participants.includes(userId)) throw notFound('call_not_found');
  return c;
}

const requireActive = (c: CallItem) => {
  if (c.endedAt) throw new HttpError(409, 'call_ended');
};

export const handler = router({
  'GET /calls/{id}/join': async ({ userId, params }) => {
    const c = await participantCall(params.id, userId);
    requireActive(c);
    const peerId = otherOf(c.participants, userId);
    const [peer, fs] = await Promise.all([getUser(peerId), getFriendship(userId, peerId)]);
    try {
      await applyEvent(c.nudgeId, { type: 'join' });
    } catch (e) {
      if (!(e instanceof HttpError)) throw e;
    }
    return {
      callId: c.id,
      meeting: c.meeting,
      attendee: c.attendees[userId],
      peer: await publicUser(peer),
      peerNickname: fs?.nickname,
      peerAttendeeId: c.attendees[peerId]?.AttendeeId,
      memoryAllowed: c.memoryAllowed,
    };
  },

  'POST /calls/{id}/end': async ({ userId, params }) => {
    await participantCall(params.id, userId);
    await endCall(params.id, userId);
  },

  'GET /calls/{id}/summary': async ({ userId, params }) => {
    const c = await participantCall(params.id, userId);
    const durationSec = c.endedAt ? Math.round((Date.parse(c.endedAt) - Date.parse(c.startedAt)) / 1000) : 0;
    const s = await get(K.summary(c.pairKey, c.id));
    if (s) {
      const topics = (await queryPrefix(`PAIR#${c.pairKey}`, 'TOPIC#')).filter((t) => t.sourceCallId === c.id);
      return {
        callId: c.id,
        summary: s.summary,
        durationSec: s.durationSec,
        createdAt: s.createdAt,
        topics: topics.map(topicDTO),
      };
    }
    if (c.summarized || (c.endedAt && !c.memoryAllowed)) {
      return { callId: c.id, summary: '', durationSec, createdAt: c.endedAt ?? c.startedAt, topics: [] };
    }
    return new Res(202, { pending: true });
  },

  'POST /calls/{id}/shares': async ({ userId, params, body }) => {
    const c = await participantCall(params.id, userId);
    requireActive(c);
    if (typeof body.photoId !== 'string') throw bad('invalid_photo');
    const photo = await get(K.photo(userId, body.photoId));
    if (!photo || photo.status !== 'indexed') throw forbidden('photo_not_shareable');
    const shareId = newId('s');
    await put({
      ...K.share(c.id, shareId),
      shareId,
      senderId: userId,
      recipientId: otherOf(c.participants, userId),
      photoId: body.photoId,
      s3Key: photo.s3Key,
      suggestionId: typeof body.suggestionId === 'string' ? body.suggestionId : undefined,
      createdAt: new Date().toISOString(),
    });
    if (typeof body.suggestionId === 'string') {
      const suggestion = await get(K.suggestion(c.id, body.suggestionId));
      if (suggestion?.userId === userId) await update(K.suggestion(c.id, body.suggestionId), { outcome: 'shared', sharedAt: new Date().toISOString() });
    }
    return { shareId, thumbUrl: await presignGet(photo.s3Key, SHARE_URL_TTL_S) };
  },

  'POST /calls/{id}/suggestions/{suggestionId}/feedback': async ({ userId, params, body }) => {
    await participantCall(params.id, userId);
    const suggestion = await get(K.suggestion(params.id, params.suggestionId));
    if (!suggestion || suggestion.userId !== userId) throw notFound('suggestion_not_found');
    const outcome = body.outcome === 'dismissed' ? 'dismissed' : undefined;
    if (!outcome) throw bad('invalid_feedback');
    await update(K.suggestion(params.id, params.suggestionId), { outcome, feedbackAt: new Date().toISOString() });
  },

  // Post-call recap: every photo either person showed, once each, oldest first. Photos since deleted are left out.
  'GET /calls/{id}/shares': async ({ userId, params }) => {
    const c = await participantCall(params.id, userId);
    if (!c.endedAt) throw new HttpError(409, 'call_active');
    if (Date.now() - Date.parse(c.endedAt) > RECAP_WINDOW_MS) return { photos: [] };
    const shares = (await queryPrefix(`CALL#${c.id}`, 'SHARE#')).sort((x, y) => String(x.createdAt).localeCompare(String(y.createdAt)));
    const seen = new Set<string>();
    const photos = [];
    for (const s of shares) {
      const key = `${s.senderId}/${s.photoId}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const photo = await get(K.photo(s.senderId, s.photoId));
      if (!photo) continue;
      photos.push({ shareId: s.shareId, senderId: s.senderId, url: await presignGet(s.s3Key, SHARE_URL_TTL_S), createdAt: s.createdAt });
    }
    return { photos };
  },

  'GET /calls/{id}/shares/{shareId}': async ({ userId, params }) => {
    const c = await participantCall(params.id, userId);
    requireActive(c);
    const s = await get(K.share(c.id, params.shareId));
    if (!s) throw notFound('share_not_found');
    if (s.recipientId !== userId) throw forbidden('not_recipient');
    return { url: await presignGet(s.s3Key, SHARE_URL_TTL_S), expiresAt: new Date(Date.now() + SHARE_URL_TTL_S * 1000).toISOString() };
  },

  'POST /calls/{id}/shares/{shareId}/shown': async ({ userId, params, body }) => {
    const c = await participantCall(params.id, userId);
    const s = await get(K.share(c.id, params.shareId));
    if (!s) throw notFound('share_not_found');
    await update(K.share(c.id, params.shareId), {
      shownAt: typeof body.shownAt === 'string' ? body.shownAt : new Date().toISOString(),
      durationMs: typeof body.durationMs === 'number' ? body.durationMs : undefined,
    });
  },
});
