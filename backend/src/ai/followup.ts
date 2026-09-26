// Auto follow-up message sent on the skipper's behalf (SPEC NUD-12).
import { converse } from './bedrock.js';

export const FALLBACK_FOLLOWUPS = [
  "Can't right now, I'll call you soon!",
  "Missed you just now, let's talk soon!",
  "Can't talk this minute, I'll call you later!",
];

export const FOLLOWUP_SYSTEM = `Write a single short text message (max 12 words) that a person sends to someone close to them after they couldn't take a call right now.
Warm, casual, natural, no emoji, no names, no apology overload, no promises of a specific time. Output only the message.`;

export async function followUpMessage(): Promise<string> {
  try {
    const text = await converse({
      system: FOLLOWUP_SYSTEM,
      temperature: 0.9,
      maxTokens: 40,
      messages: [{ role: 'user', content: [{ text: 'Write the message.' }] }],
    });
    const clean = text.trim().replace(/^["']|["']$/g, '').split('\n')[0].trim();
    if (clean.length >= 8 && clean.length <= 100 && !/[\u{1F300}-\u{1FAFF}]/u.test(clean)) return clean;
  } catch (e) {
    console.warn('followup generation failed', (e as any)?.name);
  }
  return FALLBACK_FOLLOWUPS[Math.floor(Math.random() * FALLBACK_FOLLOWUPS.length)];
}
