// Post-call summary and follow-up topics (SPEC MEM-2).
import { converse, extractJson } from './bedrock.js';

export interface TopicOut {
  title: string;
  about: 'A' | 'B';
  followUpAfter: string | null;
  summary: string;
}

export interface SummaryOut {
  summary: string;
  topics: TopicOut[];
}

export const SUMMARY_SYSTEM = `You summarize a casual video call between two people, A and B, so the app can suggest a caring follow-up later.
Return JSON only:
{"summary": "one or two neutral sentences about what they talked about",
 "topics": [{"title": "short noun phrase, lowercase, e.g. 'the physics exam'", "about": "A" or "B" (whose life event it is),
             "followUpAfter": "YYYY-MM-DD" or null, "summary": "one sentence"}]}
Rules:
- Topics are upcoming or ongoing events in someone's life worth asking about later (exam, interview, trip, move, doctor visit, game, recital, new job). 0 to 3 topics. Skip small talk.
- followUpAfter: the day after the event if a date or relative day is mentioned (resolve against TODAY); otherwise 3 days after TODAY for ongoing things; null if not worth a follow-up.
- In "summary" and each topic's "summary", call the people by the names given (NAMES), never "A" or "B".
- Never include sensitive details (health specifics, money amounts, passwords). Keep titles short enough to fit "Want to follow up about <title>?".`;

export async function summarizeCall(
  lines: { who: 'A' | 'B'; text: string }[],
  now = new Date(),
  names: { A: string; B: string } = { A: 'A', B: 'B' },
): Promise<SummaryOut> {
  if (!lines.length) return { summary: '', topics: [] };
  const transcript = lines.map((l) => `${l.who}: ${l.text}`).join('\n').slice(-12000);
  const text = await converse({
    system: SUMMARY_SYSTEM,
    maxTokens: 500,
    messages: [{ role: 'user', content: [{ text: `TODAY: ${now.toISOString().slice(0, 10)}\nNAMES: A is ${names.A}, B is ${names.B}\n\nTranscript:\n${transcript}\n\nJSON:` }] }],
  });
  const j = extractJson<SummaryOut>(text);
  if (!j) return { summary: '', topics: [] };
  const topics = (Array.isArray(j.topics) ? j.topics : [])
    .filter((t) => t && typeof t.title === 'string' && t.title.trim())
    .slice(0, 3)
    .map((t) => ({
      title: t.title.trim().slice(0, 60),
      about: t.about === 'B' ? ('B' as const) : ('A' as const),
      followUpAfter: t.followUpAfter && /^\d{4}-\d{2}-\d{2}$/.test(t.followUpAfter) ? t.followUpAfter : null,
      summary: String(t.summary ?? '').slice(0, 300),
    }));
  return { summary: String(j.summary ?? '').slice(0, 600), topics };
}
