// Transcript segment → detector → retrieval → photo.suggestion (SPEC REF-1..6, REF-10).
import { detectReference } from '../ai/detector.js';
import { embedText } from '../ai/embed.js';
import { get, put, query, queryPrefix } from './db.js';
import { env } from './env.js';
import { getCall } from './flows.js';
import { K, newId, segSk } from './keys.js';
import { emitLatency, stopwatch } from './metrics.js';
import { presignGet } from './s3.js';
import { getUser } from './users.js';
import { queryPhotos, type VectorHit } from './vectors.js';
import { sendToUser } from './ws.js';

const CONTEXT_MS = 60_000;
const MIN_CONFIDENCE = 0.5;
const DAY = 86_400;

export interface TranscriptInput {
  callId: string;
  segId: string;
  text: string;
  startMs?: number;
  endMs?: number;
  clientTs?: number;
}

/** Converts a YYYY-MM-DD hint into an inclusive epoch-second range with a day of slack for time zones. */
export function dateRange(hint?: { from?: string; to?: string }): { fromSec?: number; toSec?: number } {
  if (!hint) return {};
  const from = hint.from ? Date.parse(`${hint.from}T00:00:00Z`) / 1000 - DAY : undefined;
  const to = hint.to ? Date.parse(`${hint.to}T23:59:59Z`) / 1000 + DAY : from !== undefined ? from + 3 * DAY : undefined;
  return { fromSec: Number.isFinite(from) ? from : undefined, toSec: Number.isFinite(to) ? to : undefined };
}

/** Picks the best hit above the threshold that hasn't been suggested in this call yet. */
export function pickHit(hits: VectorHit[], threshold: number, alreadySuggested: Set<string>): VectorHit | undefined {
  return hits
    .filter((h) => h.similarity >= threshold && !alreadySuggested.has(h.key))
    .sort((a, b) => b.similarity - a.similarity)[0];
}

export async function handleTranscript(userId: string, input: TranscriptInput) {
  const sw = stopwatch();
  const receivedAt = Date.now();
  const call = await getCall(input.callId);
  if (!call.participants.includes(userId) || call.endedAt) return { stored: false };
  const text = String(input.text ?? '').trim().slice(0, 2000);
  if (!text) return { stored: false };
  const currentSk = segSk(receivedAt, userId, String(input.segId ?? newId('g')).slice(0, 64));
  await put({
    pk: `CALL#${call.id}`,
    sk: currentSk,
    userId,
    text,
    startMs: input.startMs,
    endMs: input.endMs,
    clientTs: input.clientTs,
    ttl: Math.floor(receivedAt / 1000) + DAY,
  });
  sw.lap('store');

  const user = await getUser(userId);
  if (user.settings.photoMode === 'off' || text.split(/\s+/).length < 3) return { stored: true };

  const segs = await query({
    KeyConditionExpression: 'pk = :pk AND sk BETWEEN :lo AND :hi',
    ExpressionAttributeValues: {
      ':pk': `CALL#${call.id}`,
      ':lo': segSk(receivedAt - CONTEXT_MS, '', ''),
      ':hi': segSk(receivedAt + 1, '~', '~'),
    },
  });
  sw.lap('context');
  // The segment just received is always the line being judged, even if the friend's segment landed after it.
  const window = [...segs.filter((s) => s.sk !== currentSk).map((s) => ({ userId: s.userId, text: s.text })), { userId, text }];
  const detection = await detectReference(window, userId);
  sw.lap('detector');
  if (!detection.isReference || detection.confidence < MIN_CONFIDENCE) {
    emitLatency(sw.total(), { pipeline: 'reference' }, { callId: call.id, outcome: 'no_reference' });
    return { stored: true, detection };
  }

  const vec = await embedText([detection.query, detection.placeHint].filter(Boolean).join(', '));
  sw.lap('embed');
  const range = dateRange(detection.dateHint);
  let hits = await queryPhotos(userId, vec, { topK: 5, ...range });
  const suggested = new Set(
    (await queryPrefix(`CALL#${call.id}`, 'SUGG#')).filter((s) => s.userId === userId).map((s) => `${userId}#${s.photoId}`),
  );
  let best = pickHit(hits, env.similarityThreshold, suggested);
  if (!best && (range.fromSec || range.toSec)) {
    hits = await queryPhotos(userId, vec, { topK: 5 });
    best = pickHit(hits, env.similarityThreshold, suggested);
  }
  sw.lap('search');
  if (!best) {
    emitLatency(sw.total(), { pipeline: 'reference' }, { callId: call.id, outcome: 'no_match', topSimilarity: hits[0]?.similarity });
    return { stored: true, detection };
  }
  const photoId = best.key.split('#')[1];
  const photo = await get(K.photo(userId, photoId));
  if (!photo || photo.status !== 'indexed') return { stored: true, detection };
  const suggestionId = newId('g');
  const thumbUrl = await presignGet(photo.s3Key, 300);
  const auto = user.settings.photoMode === 'auto';
  await sendToUser(userId, {
    type: 'photo.suggestion',
    callId: call.id,
    suggestionId,
    photoId,
    thumbUrl,
    query: detection.query,
    confidence: detection.confidence,
    auto,
  });
  sw.lap('push');
  const stages = sw.total();
  await put({
    pk: `CALL#${call.id}`,
    sk: `SUGG#${suggestionId}`,
    userId,
    photoId,
    query: detection.query,
    confidence: detection.confidence,
    similarity: best.similarity,
    createdAt: new Date().toISOString(),
    stages,
    ttl: Math.floor(Date.now() / 1000) + DAY,
  });
  emitLatency(stages, { pipeline: 'reference' }, { callId: call.id, outcome: 'suggested', similarity: best.similarity });
  return { stored: true, detection, suggestionId, photoId, similarity: best.similarity };
}
