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

export const DETECTOR_SYSTEM = `You watch a live video call between two friends. You get up to a minute of earlier transcript for context, then SPEAKER's LAST LINE.
Lines from the person whose camera roll we can search are labeled SPEAKER; the other person is FRIEND.
Judge ONLY the LAST LINE. Earlier lines are context for resolving words like "it" or "that" — they may mention other things (even other photo-worthy things) that must NOT be used for the query.
Decide whether the LAST LINE refers to a specific, concrete thing SPEAKER personally saw, made, did, or visited recently (within about the last month) that SPEAKER would plausibly have a photo of in their own camera roll — e.g. a trip, hike, meal, dish they cooked, pet, new purchase, event they attended, place, outfit, haircut, project they built.

Answer NO when the last line is:
- small talk, feelings, opinions, logistics, work or school talk without a concrete visual thing
- about the future or a plan ("we should go hiking")
- about FRIEND's experience, or something SPEAKER only heard about or saw online/TV
- about something long ago (childhood, years back)
- SPEAKER saying they have no photo ("I didn't take any pictures")
- a question asking FRIEND about FRIEND's things
- too vague to search ("that thing", "stuff") unless earlier lines make it concrete

When it is a reference, write "query": a short visual search phrase (3–8 words) describing what SPEAKER's photo of the LAST LINE's subject would show, built from the LAST LINE's words (earlier lines only to resolve "it"/"that"). Do not invent details that weren't said.
"dateHint": ISO dates {"from","to"} only if SPEAKER gives a time ("last weekend", "yesterday", "on the 12th"); resolve against TODAY. Otherwise omit it.
"placeHint": a place name only if one is said. Otherwise omit it.
"confidence": a number from 0 to 1.

Reply with one JSON object only, using the literal values true or false for isReference:
{"isReference": true, "query": "...", "dateHint": {"from": "YYYY-MM-DD", "to": "YYYY-MM-DD"}, "placeHint": "...", "confidence": 0.8}
or {"isReference": false, "query": "", "confidence": 0.9}`;

export function formatTranscript(segments: Segment[], speakerId: string): string {
  return segments.map((s) => `${s.userId === speakerId ? 'SPEAKER' : 'FRIEND'}: ${s.text.trim()}`).join('\n');
}

/** Builds the prompt body: earlier lines as context, then the speaker's last line on its own. */
export function formatPrompt(segments: Segment[], speakerId: string, today: string, weekday: string): string {
  let lastIdx = -1;
  for (let i = segments.length - 1; i >= 0; i--) if (segments[i].userId === speakerId) { lastIdx = i; break; }
  const context = segments.filter((_, i) => i !== lastIdx);
  const last = lastIdx >= 0 ? segments[lastIdx].text.trim() : '';
  return (
    `TODAY: ${today} (${weekday})\n\n` +
    `Earlier lines (context only):\n${context.length ? formatTranscript(context, speakerId) : '(none)'}\n\n` +
    `LAST LINE (SPEAKER) — judge only this:\n"${last}"\n\nJSON:`
  );
}

export async function detectReference(segments: Segment[], speakerId: string, now = new Date()): Promise<Detection> {
  if (!segments.some((s) => s.userId === speakerId)) return { isReference: false, query: '', confidence: 0 };
  const today = now.toISOString().slice(0, 10);
  const weekday = now.toLocaleDateString('en-US', { weekday: 'long', timeZone: 'UTC' });
  const text = await converse({
    system: DETECTOR_SYSTEM,
    maxTokens: 150,
    messages: [
      {
        role: 'user',
        content: [{ text: formatPrompt(segments, speakerId, today, weekday) }],
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
