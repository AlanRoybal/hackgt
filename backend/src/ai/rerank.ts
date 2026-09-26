// Small, bounded second-stage ranker for ambiguous photo retrieval candidates.
import { converse, extractJson } from './bedrock.js';

export interface RerankCandidate {
  key: string;
  caption?: string;
  place?: string;
  takenAt?: number;
}

export interface RerankDecision {
  key?: string;
  confidence: number;
}

const SYSTEM = `You select the one personal photo that best matches a recent spoken reference during a call.
Use only the supplied candidate metadata. Choose none if no candidate clearly matches; never guess.
The concrete subject and activity are essential. A shared city, date, or venue alone is NOT a match.
A reference to eating ramen in Houston requires evidence of ramen or a matching meal, not a Houston skyline or street.
If metadata cannot establish the subject, choose none. Preserve explicit details and negations in the spoken reference.
Return JSON only: {"choice": 1, "confidence": 0.0} where choice is a candidate number, or {"choice": null, "confidence": 0.0}.`;

export function parseRerank(text: string, candidates: RerankCandidate[]): RerankDecision | undefined {
  const value = extractJson<{ choice?: unknown; confidence?: unknown }>(text);
  if (!value) return undefined;
  const confidence = typeof value.confidence === 'number' ? Math.max(0, Math.min(1, value.confidence)) : 0;
  if (value.choice === null) return { confidence: 0 };
  if (!Number.isInteger(value.choice) || (value.choice as number) < 1 || (value.choice as number) > candidates.length) return undefined;
  return { key: candidates[(value.choice as number) - 1].key, confidence };
}

export async function rerankPhotos(reference: string, candidates: RerankCandidate[]): Promise<RerankDecision | undefined> {
  if (!candidates.length) return undefined;
  const rows = candidates.map((c, i) => ({
    choice: i + 1,
    caption: c.caption ?? '',
    place: c.place ?? '',
    takenAt: c.takenAt ? new Date(c.takenAt * 1000).toISOString().slice(0, 10) : '',
  }));
  const text = await converse({
    system: SYSTEM,
    maxTokens: 100,
    messages: [{ role: 'user', content: [{ text: JSON.stringify({ reference, candidates: rows }) }] }],
  });
  return parseRerank(text, candidates);
}
