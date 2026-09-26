// Transcript segment → detector → retrieval → photo.suggestion for a photo or short video (SPEC REF-1..6, REF-10, VID-3).
import { detectReference, retrievalQueries } from '../ai/detector.js';
import { embedText } from '../ai/embed.js';
import { rerankPhotos } from '../ai/rerank.js';
import { get, put, query, queryPrefix, del, isConditionalFailure } from './db.js';
import { env } from './env.js';
import { getCall } from './flows.js';
import { K, newId, segSk } from './keys.js';
import { mediaTypeOf } from './media.js';
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
export const PHOTO_REPEAT_COOLDOWN_MS = 10_000;

/** Deduplicate ASR revisions and brief bursts, not an entire conversation. */
export function suppressRepeat(suggestions: { photoId: string; createdAt?: string; sourceSegId?: string }[], photoId: string, segId: string | undefined, now: number): boolean {
  return suggestions.some(s => s.photoId === photoId && (
    (!!segId && s.sourceSegId === segId) ||
    (s.createdAt !== undefined && now - Date.parse(s.createdAt) >= 0 && now - Date.parse(s.createdAt) < PHOTO_REPEAT_COOLDOWN_MS)
  ));
}
/** How far back the friend's speech can be and still come through this speaker's mic as echo. */
const ECHO_WINDOW_MS = 15_000;
const ECHO_MIN_OVERLAP = 0.7;
// Simultaneous microphone pickup cannot establish who spoke. Only a clearly earlier line can veto.
const ECHO_LEAD_MS = 750;

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
 * the friend just said. Require a long matching sequence; common vocabulary alone isn't evidence.
 */
export function isLikelyEcho(text: string, friendTexts: string[]): boolean {
  const mine = words(text);
  if (mine.length < 5) return false;
  // Require a near-verbatim sequence in a single utterance, not common words pooled across a conversation.
  return friendTexts.some(friend => {
    const theirs = words(friend);
    let longest = 0;
    let previous = new Uint16Array(theirs.length + 1);
    for (const word of mine) {
      const row = new Uint16Array(theirs.length + 1);
      for (let j = 0; j < theirs.length; j++) {
        if (word === theirs[j]) row[j + 1] = previous[j] + 1;
        longest = Math.max(longest, row[j + 1]);
      }
      previous = row;
    }
    return longest >= 5 && longest / mine.length >= ECHO_MIN_OVERLAP;
  });
}

const segTimeMs = (sk: string) => Number(sk.split('#')[1]);

/** The friend's finals and latest partial received since `sinceMs`. */
async function friendSpeech(callId: string, friendId: string | undefined, sinceMs: number, beforeMs: number): Promise<string[]> {
  if (!friendId) return [];
  const [segs, live] = await Promise.all([
    query({
      KeyConditionExpression: 'pk = :pk AND sk BETWEEN :lo AND :hi',
      ExpressionAttributeValues: { ':pk': `CALL#${callId}`, ':lo': segSk(sinceMs, '', ''), ':hi': segSk(beforeMs, '~', '~') },
      ConsistentRead: true,
    }),
    query({
      KeyConditionExpression: 'pk = :pk AND sk = :sk',
      ExpressionAttributeValues: { ':pk': K.callLive(callId, friendId).pk, ':sk': K.callLive(callId, friendId).sk },
      ConsistentRead: true,
    }),
  ]);
  return [...segs, ...live.filter((l) => Number(l.at) >= sinceMs)]
    .filter((s) => s.userId === friendId && (s.at === undefined ? segTimeMs(s.sk) : Number(s.at)) <= beforeMs)
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
  const recentFriend = segs.filter((s) => s.userId === friendId && segTimeMs(s.sk) >= echoSince && segTimeMs(s.sk) <= receivedAt - ECHO_LEAD_MS).map((s) => String(s.text));
  const live = friendId ? await get(K.callLive(call.id, friendId)) : undefined;
  if (live && Number(live.at) >= echoSince && Number(live.at) <= receivedAt - ECHO_LEAD_MS) recentFriend.push(String(live.text));
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
  const suggestions = (await queryPrefix<{ userId: string; photoId: string; createdAt?: string; sourceSegId?: string }>(`CALL#${call.id}`, 'SUGG#')).filter(s => s.userId === userId);
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
  // Use the same earlier-than-input cutoff on recheck. Later speech must never retroactively veto the original speaker.
  if (isLikelyEcho(text, await friendSpeech(call.id, friendId, echoSince, receivedAt - ECHO_LEAD_MS))) {
    emitLatency(sw.total(), { pipeline: 'reference' }, { callId: call.id, outcome: 'echo' });
    return { stored: !input.isPartial, outcome: 'echo' };
  }
  const photoId = best.key.split('#')[1];
  // Keep ranking all photos: a duplicate winner must never promote an unrelated runner-up.
  if (suppressRepeat(suggestions, photoId, input.segId, Date.now())) {
    emitLatency(sw.total(), { pipeline: 'reference' }, { callId: call.id, outcome: 'repeat_cooldown' });
    return { stored: !input.isPartial, outcome: 'repeat_cooldown' };
  }
  if (Date.now() - receivedAt > 12_000 || (await getCall(call.id)).endedAt) {
    emitLatency(sw.total(), { pipeline: 'reference' }, { callId: call.id, outcome: 'stale_or_ended' });
    return { stored: !input.isPartial, outcome: 'suppressed' };
  }
  const photo = await get(K.photo(userId, photoId));
  if (!photo || photo.status !== 'indexed') return { stored: true, detection };
  const suggestionId = newId('g');
  const thumbUrl = await presignGet(photo.s3Key, 300);
  const video = mediaTypeOf(photo) === 'video';
  const auto = user.settings.photoMode === 'auto' && !input.isPartial;
  await sendToUser(userId, {
    type: 'photo.suggestion',
    callId: call.id,
    suggestionId,
    photoId,
    thumbUrl,
    // A video's thumb is its poster frame; the speaker's phone plays the clip from `videoUrl` (VID-3).
    ...(video ? { mediaType: 'video', durationMs: photo.durationMs, videoUrl: await presignGet(photo.videoKey, 300) } : {}),
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
    sourceSegId: input.segId,
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
