// In-call photo reference detector (SPEC REF-2). Shared by the transcript Lambda and evals/detector.
import { converse, extractJson } from './bedrock.js';

export interface Segment {
  userId: string;
  text: string;
}

export interface Detection {
  isReference: boolean;
  query: string;
  dateHint?: { from?: string; to?: string };
  placeHint?: string;
  confidence: number;
}

export const DETECTOR_SYSTEM = `You watch a live video call between two friends. You see the last minute of transcript.
Lines from the person whose camera roll we can search are labeled SPEAKER; the other person is FRIEND.
Decide whether SPEAKER's LAST line refers to a specific, concrete thing SPEAKER personally saw, made, did, or visited recently (within about the last month) that SPEAKER would plausibly have a photo of in their own camera roll — e.g. a trip, hike, meal, dish they cooked, pet, new purchase, event they attended, place, outfit, haircut, project they built.

Answer NO when the last line is:
- small talk, feelings, opinions, logistics, work or school talk without a concrete visual thing
- about the future or a plan ("we should go hiking")
- about FRIEND's experience, or something SPEAKER only heard about or saw online/TV
- about something long ago (childhood, years back)
- SPEAKER saying they have no photo ("I didn't take any pictures")
- a question asking FRIEND about FRIEND's things
- too vague to search ("that thing", "stuff") unless earlier lines make it concrete

When YES, write "query": a short visual search phrase describing what the photo would show (use earlier lines to resolve "it"/"that"), e.g. "golden retriever puppy on a couch", "homemade lasagna", "sunset hike at a mountain lake".
"dateHint": ISO dates {"from","to"} only if SPEAKER gives a time ("last weekend", "yesterday", "on the 12th"); resolve against TODAY. Otherwise omit.
"placeHint": a place name only if one is said. Otherwise omit.
"confidence": 0 to 1.

Reply with JSON only: {"isReference": boolean, "query": string, "dateHint": {"from": "YYYY-MM-DD", "to": "YYYY-MM-DD"}, "placeHint": string, "confidence": number}`;

export function formatTranscript(segments: Segment[], speakerId: string): string {
  return segments.map((s) => `${s.userId === speakerId ? 'SPEAKER' : 'FRIEND'}: ${s.text.trim()}`).join('\n');
}

export async function detectReference(segments: Segment[], speakerId: string, now = new Date()): Promise<Detection> {
  if (!segments.length) return { isReference: false, query: '', confidence: 0 };
  const today = now.toISOString().slice(0, 10);
  const weekday = now.toLocaleDateString('en-US', { weekday: 'long', timeZone: 'UTC' });
  const text = await converse({
    system: DETECTOR_SYSTEM,
    maxTokens: 150,
    messages: [
      {
        role: 'user',
        content: [{ text: `TODAY: ${today} (${weekday})\n\nTranscript:\n${formatTranscript(segments, speakerId)}\n\nJSON:` }],
      },
    ],
  });
  const j = extractJson<Detection>(text);
  if (!j || typeof j.isReference !== 'boolean') return { isReference: false, query: '', confidence: 0 };
  const iso = (s?: string) => (s && /^\d{4}-\d{2}-\d{2}/.test(s) ? s.slice(0, 10) : undefined);
  const dateHint = j.dateHint && (iso(j.dateHint.from) || iso(j.dateHint.to)) ? { from: iso(j.dateHint.from), to: iso(j.dateHint.to) } : undefined;
  return {
    isReference: j.isReference && !!j.query?.trim(),
    query: (j.query ?? '').trim(),
    dateHint,
    placeHint: j.placeHint?.trim() || undefined,
    confidence: typeof j.confidence === 'number' ? Math.max(0, Math.min(1, j.confidence)) : j.isReference ? 0.7 : 0,
  };
}
