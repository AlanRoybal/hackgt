// Transcript segment → detector → retrieval → photo.suggestion (SPEC REF-1..6, REF-10).
import { detectReference, retrievalQueries } from '../ai/detector.js';
import { embedText } from '../ai/embed.js';
import { rerankPhotos } from '../ai/rerank.js';
import { get, put, query, queryPrefix, del, isConditionalFailure } from './db.js';
import { env } from './env.js';
import { getCall } from './flows.js';
import { K, newId, segSk } from './keys.js';
import { emitLatency, stopwatch } from './metrics.js';
import { presignGet } from './s3.js';
import { getUser } from './users.js';
import { queryCaptionPhotos, queryPhotos, type VectorHit } from './vectors.js';
import { sendToUser } from './ws.js';

const CONTEXT_MS = 60_000;
const MIN_CONFIDENCE = 0.5;
const DAY = 86_400;
const RETRIEVAL_TOP_K = 10;
const RERANK_TOP_K = 8;
const MIN_RERANK_CONFIDENCE = 0.55;
/** How far back the friend's speech can be and still come through this speaker's mic as echo. */
const ECHO_WINDOW_MS = 15_000;
const ECHO_MIN_OVERLAP = 0.7;

export interface TranscriptInput {
  callId: string;
  segId: string;
  text: string;
  startMs?: number;
  endMs?: number;
  clientTs?: number;
  isPartial?: boolean;
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
    .sort((a, b) => Number(b.metadata.fusionScore ?? b.similarity) - Number(a.metadata.fusionScore ?? a.similarity))[0];
}

/**
 * Reciprocal-rank fusion preserves strong visual matches while allowing caption matches to recover
 * named places, events, and activities that are not visually distinctive.
 */
export function fusePhotoHits(
  imageGroups: VectorHit[][],
  captionGroups: VectorHit[][],
  placeHint?: string,
): VectorHit[] {
  const byKey = new Map<string, VectorHit>();
  const add = (hits: VectorHit[], source: 'image' | 'caption') => {
    hits.forEach((hit, rank) => {
      const prior = byKey.get(hit.key);
      const metadata = { ...(prior?.metadata ?? {}), ...hit.metadata };
      const score = Number(prior?.metadata.fusionScore ?? 0) + (source === 'image' ? 1 : 0.8) / (60 + rank + 1);
      metadata.fusionScore = score;
      metadata[`${source}Similarity`] = Math.max(Number(prior?.metadata[`${source}Similarity`] ?? -1), hit.similarity);
      byKey.set(hit.key, { key: hit.key, similarity: Math.max(prior?.similarity ?? -1, hit.similarity), metadata });
    });
  };
  imageGroups.forEach((hits) => add(hits, 'image'));
  captionGroups.forEach((hits) => add(hits, 'caption'));

  const hint = new Set((placeHint ?? '').toLowerCase().match(/[a-z0-9]+/g) ?? []);
  for (const hit of byKey.values()) {
    const place = new Set(String(hit.metadata.place ?? '').toLowerCase().match(/[a-z0-9]+/g) ?? []);
    const overlap = [...hint].filter((word) => place.has(word)).length;
    if (overlap) hit.metadata.fusionScore = Number(hit.metadata.fusionScore) + Math.min(overlap, 3) * 0.002;
  }
  return [...byKey.values()].sort((a, b) => Number(b.metadata.fusionScore) - Number(a.metadata.fusionScore));
}

const words = (text: string) => text.toLowerCase().match(/[a-z0-9']+/g) ?? [];

/**
 * On speakerphone the friend's voice reaches this user's mic, so their transcript can repeat what
 * the friend just said. A line is echo when most of its words were in the friend's recent speech.
 */
export function isLikelyEcho(text: string, friendTexts: string[]): boolean {
  const mine = words(text);
  if (mine.length < 3) return false;
  const theirs = new Set(friendTexts.flatMap(words));
  if (!theirs.size) return false;
  return mine.filter((w) => theirs.has(w)).length / mine.length >= ECHO_MIN_OVERLAP;
}

const segTimeMs = (sk: string) => Number(sk.split('#')[1]);

/** The friend's finals and latest partial received since `sinceMs`. */
async function friendSpeech(callId: string, friendId: string | undefined, sinceMs: number): Promise<string[]> {
  if (!friendId) return [];
  const [segs, live] = await Promise.all([
    query({
      KeyConditionExpression: 'pk = :pk AND sk BETWEEN :lo AND :hi',
      ExpressionAttributeValues: { ':pk': `CALL#${callId}`, ':lo': segSk(sinceMs, '', ''), ':hi': segSk(Date.now() + 1, '~', '~') },
      ConsistentRead: true,
    }),
    query({
      KeyConditionExpression: 'pk = :pk AND sk = :sk',
      ExpressionAttributeValues: { ':pk': K.callLive(callId, friendId).pk, ':sk': K.callLive(callId, friendId).sk },
      ConsistentRead: true,
    }),
  ]);
  return [...segs, ...live.filter((l) => Number(l.at) >= sinceMs)]
    .filter((s) => s.userId === friendId)
    .map((s) => String(s.text ?? ''));
}

export async function handleTranscript(userId: string, input: TranscriptInput) {
  const sw = stopwatch();
  const receivedAt = Date.now();
  const call = await getCall(input.callId);
  if (!call.participants.includes(userId) || call.endedAt) return { stored: false };
  const text = String(input.text ?? '').trim().slice(0, 2000);
  if (!text) return { stored: false };
  const currentSk = segSk(receivedAt, userId, String(input.segId ?? newId('g')).slice(0, 64));
  if (!input.isPartial) await put({
    pk: `CALL#${call.id}`,
    sk: currentSk,
    userId,
    segId: input.segId,
    text,
    startMs: input.startMs,
    endMs: input.endMs,
    clientTs: input.clientTs,
    ttl: Math.floor(receivedAt / 1000) + DAY,
  });
  // Finals can trail the words by seconds; the latest partial lets the friend's echo check see them sooner.
  else await put({ ...K.callLive(call.id, userId), userId, text, at: receivedAt, ttl: Math.floor(receivedAt / 1000) + DAY });
  sw.lap('store');
  const friendId = call.participants.find((p: string) => p !== userId);

  const user = await getUser(userId);
  if (user.settings.photoMode === 'off' || text.split(/\s+/).length < 3) return { stored: true };

  // Bound model fan-out across concurrent Lambda invocations. Finals still enter history above.
  const lease = { pk: `CALL#${call.id}`, sk: `RETRIEVAL#${userId}` };
  const owner = newId('r');
  for (let attempt = 0; ; attempt++) {
    try {
      await put({ ...lease, leaseToken: owner, expiresAt: Date.now() + 30_000, ttl: Math.floor(receivedAt / 1000) + DAY },
        'attribute_not_exists(pk) OR expiresAt < :now', { ':now': Date.now() });
      break;
    } catch (e) {
      if (!isConditionalFailure(e)) throw e;
      if (input.isPartial || attempt >= 24) return { stored: !input.isPartial, outcome: 'busy' };
      // A corrected final must get a turn even when the last partial is in flight.
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
  try {

  const segs = await query({
    KeyConditionExpression: 'pk = :pk AND sk BETWEEN :lo AND :hi',
    ExpressionAttributeValues: {
      ':pk': `CALL#${call.id}`,
      ':lo': segSk(receivedAt - CONTEXT_MS, '', ''),
      ':hi': segSk(receivedAt + 1, '~', '~'),
    },
  });
  sw.lap('context');
  const echoSince = receivedAt - ECHO_WINDOW_MS;
  const recentFriend = segs.filter((s) => s.userId === friendId && segTimeMs(s.sk) >= echoSince).map((s) => String(s.text));
  const live = friendId ? await get(K.callLive(call.id, friendId)) : undefined;
  if (live && Number(live.at) >= echoSince) recentFriend.push(String(live.text));
  if (isLikelyEcho(text, recentFriend)) {
    emitLatency(sw.total(), { pipeline: 'reference' }, { callId: call.id, outcome: 'echo' });
    return { stored: !input.isPartial, outcome: 'echo' };
  }
  // The segment just received is always the line being judged, even if the friend's segment landed after it.
  const window = [...segs.filter((s) => s.sk !== currentSk).map((s) => ({ userId: s.userId, text: s.text })), { userId, text }];
  const detection = await detectReference(window, userId);
  sw.lap('detector');
  if (!detection.isReference || detection.confidence < MIN_CONFIDENCE) {
    emitLatency(sw.total(), { pipeline: 'reference' }, { callId: call.id, outcome: 'no_reference' });
    return { stored: true, detection };
  }

  const queries = retrievalQueries(detection);
  // Keep subject embeddings distinct from the location boost; repeating a city in
  // every query can drown out the actual meal/object the speaker describes.
  const vectors = await Promise.all(queries.map((q) => embedText(q)));
  sw.lap('embed');
  const range = dateRange(detection.dateHint);
  const search = async (opts: { fromSec?: number; toSec?: number }) => {
    const [imageGroups, captionGroups] = await Promise.all([
      Promise.all(vectors.map((vec) => queryPhotos(userId, vec, { topK: RETRIEVAL_TOP_K, ...opts }))),
      Promise.all(vectors.map((vec) => queryCaptionPhotos(userId, vec, { topK: RETRIEVAL_TOP_K, ...opts }).catch(() => []))),
    ]);
    return fusePhotoHits(imageGroups, captionGroups, detection.placeHint);
  };
  let hits = await search(range);
  const suggested = new Set(
    (await queryPrefix(`CALL#${call.id}`, 'SUGG#')).filter((s) => s.userId === userId).map((s) => `${userId}#${s.photoId}`),
  );
  let best = pickHit(hits, env.similarityThreshold, new Set());
  if (!best && (range.fromSec || range.toSec)) {
    hits = await search({});
    best = pickHit(hits, env.similarityThreshold, new Set());
  }
  sw.lap('search');
  if (!best) {
    emitLatency(sw.total(), { pipeline: 'reference' }, { callId: call.id, outcome: 'no_match', candidateCount: hits.length, topSimilarity: hits[0]?.similarity });
    return { stored: true, detection };
  }
  const finalists = hits
    .filter((hit) => hit.similarity >= env.similarityThreshold)
    .slice(0, RERANK_TOP_K);
  let rerankConfidence: number | undefined;
  try {
    const decision = await rerankPhotos(JSON.stringify({ spokenReference: text, query: detection.query, placeHint: detection.placeHint }), finalists.map((hit) => ({
      key: hit.key,
      caption: typeof hit.metadata.caption === 'string' ? hit.metadata.caption : undefined,
      place: typeof hit.metadata.place === 'string' ? hit.metadata.place : undefined,
      takenAt: Number(hit.metadata.takenAt) || undefined,
    })));
    if (!decision) return { stored: !input.isPartial, outcome: 'rerank_invalid' };
    if (decision) {
      rerankConfidence = decision.confidence;
      if (!decision.key || decision.confidence < MIN_RERANK_CONFIDENCE) {
        emitLatency(sw.total(), { pipeline: 'reference' }, { callId: call.id, outcome: 'rerank_no_match', candidateCount: finalists.length, rerankConfidence });
        return { stored: true, detection };
      }
      best = finalists.find((hit) => hit.key === decision.key) ?? best;
    }
  } catch (e) {
    console.warn('photo rerank failed', (e as Error).name);
    return { stored: !input.isPartial, outcome: 'rerank_unavailable' };
  }
  sw.lap('rerank');
  if (input.isPartial) {
    const finals = await query({
      KeyConditionExpression: 'pk = :pk AND sk BETWEEN :lo AND :hi',
      ExpressionAttributeValues: { ':pk': `CALL#${call.id}`, ':lo': segSk(receivedAt, '', ''), ':hi': segSk(Date.now() + 1, '~', '~') },
      ConsistentRead: true,
    });
    // A final may correct a name or append a negation. Let that final's queued search decide.
    if (finals.some((s) => s.userId === userId && s.segId === input.segId)) {
      return { stored: false, outcome: 'superseded' };
    }
  }
  // The friend's own words for this line may have landed while we searched.
  if (isLikelyEcho(text, await friendSpeech(call.id, friendId, echoSince))) {
    emitLatency(sw.total(), { pipeline: 'reference' }, { callId: call.id, outcome: 'echo' });
    return { stored: !input.isPartial, outcome: 'echo' };
  }
  // Repeated references must not promote an unrelated runner-up after the right photo was shown.
  if (suggested.has(best.key) || Date.now() - receivedAt > 12_000 || (await getCall(call.id)).endedAt) {
    return { stored: !input.isPartial, outcome: 'suppressed' };
  }
  const photoId = best.key.split('#')[1];
  const photo = await get(K.photo(userId, photoId));
  if (!photo || photo.status !== 'indexed') return { stored: true, detection };
  const suggestionId = newId('g');
  const thumbUrl = await presignGet(photo.s3Key, 300);
  const auto = user.settings.photoMode === 'auto' && !input.isPartial;
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
    fusionScore: best.metadata.fusionScore,
    candidateCount: hits.length,
    queryCount: queries.length,
    rerankConfidence,
    createdAt: new Date().toISOString(),
    stages,
    ttl: Math.floor(Date.now() / 1000) + DAY,
  });
  emitLatency(stages, { pipeline: 'reference' }, { callId: call.id, outcome: 'suggested', similarity: best.similarity });
  return { stored: true, detection, suggestionId, photoId, similarity: best.similarity };
  } finally {
    try { await del(lease, 'leaseToken = :owner', { ':owner': owner }); }
    catch (e) { if (!isConditionalFailure(e)) throw e; }
  }
}
