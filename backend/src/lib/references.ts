// Transcript segment → detector → retrieval → photo.suggestion (SPEC REF-1..6, REF-10).
import { detectReference, retrievalQueries } from '../ai/detector.js';
import { embedText } from '../ai/embed.js';
import { rerankPhotos } from '../ai/rerank.js';
import { get, put, query, queryPrefix } from './db.js';
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

  const queries = retrievalQueries(detection);
  const vectors = await Promise.all(queries.map((q) => embedText([q, detection.placeHint].filter(Boolean).join(', '))));
  sw.lap('embed');
  const range = dateRange(detection.dateHint);
  const search = async (opts: { fromSec?: number; toSec?: number }) => {
    const imageGroups = await Promise.all(vectors.map((vec) => queryPhotos(userId, vec, { topK: RETRIEVAL_TOP_K, ...opts })));
    // The caption index is introduced additively; unavailable/migrating indexes must not block call suggestions.
    const captionGroups = await Promise.all(vectors.map((vec) => queryCaptionPhotos(userId, vec, { topK: RETRIEVAL_TOP_K, ...opts }).catch(() => [])));
    return fusePhotoHits(imageGroups, captionGroups, detection.placeHint);
  };
  let hits = await search(range);
  const suggested = new Set(
    (await queryPrefix(`CALL#${call.id}`, 'SUGG#')).filter((s) => s.userId === userId).map((s) => `${userId}#${s.photoId}`),
  );
  let best = pickHit(hits, env.similarityThreshold, suggested);
  if (!best && (range.fromSec || range.toSec)) {
    hits = await search({});
    best = pickHit(hits, env.similarityThreshold, suggested);
  }
  sw.lap('search');
  if (!best) {
    emitLatency(sw.total(), { pipeline: 'reference' }, { callId: call.id, outcome: 'no_match', candidateCount: hits.length, topSimilarity: hits[0]?.similarity });
    return { stored: true, detection };
  }
  const finalists = hits
    .filter((hit) => hit.similarity >= env.similarityThreshold && !suggested.has(hit.key))
    .slice(0, RERANK_TOP_K);
  let rerankConfidence: number | undefined;
  try {
    const decision = await rerankPhotos(detection.query, finalists.map((hit) => ({
      key: hit.key,
      caption: typeof hit.metadata.caption === 'string' ? hit.metadata.caption : undefined,
      place: typeof hit.metadata.place === 'string' ? hit.metadata.place : undefined,
      takenAt: Number(hit.metadata.takenAt) || undefined,
    })));
    if (decision) {
      rerankConfidence = decision.confidence;
      if (!decision.key || decision.confidence < MIN_RERANK_CONFIDENCE) {
        emitLatency(sw.total(), { pipeline: 'reference' }, { callId: call.id, outcome: 'rerank_no_match', candidateCount: finalists.length, rerankConfidence });
        return { stored: true, detection };
      }
      best = finalists.find((hit) => hit.key === decision.key) ?? best;
    }
  } catch (e) {
    // Preserve the fast vector-only path if Bedrock is briefly unavailable.
    console.warn('photo rerank failed', (e as Error).name);
  }
  sw.lap('rerank');
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
}
