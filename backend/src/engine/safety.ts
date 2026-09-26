// Photo safety rules (SPEC PHO-2). Pure — the indexer feeds it Rekognition output.

/** Rekognition v7 top-level categories that make a photo unsearchable. */
export const EXCLUDED_MODERATION = [
  'Explicit',
  'Explicit Nudity', // v6 name
  'Non-Explicit Nudity of Intimate parts and Kissing',
  'Non-Explicit Nudity',
  'Violence',
  'Visually Disturbing',
  'Hate Symbols',
  'Rude Gestures',
];

export interface ModerationLabel {
  Name?: string;
  ParentName?: string;
  Confidence?: number;
}

export function moderationVerdict(labels: ModerationLabel[], minConfidence = 60): { safe: boolean; hits: string[] } {
  const hits = new Set<string>();
  for (const l of labels) {
    if ((l.Confidence ?? 0) < minConfidence) continue;
    for (const n of [l.Name, l.ParentName]) if (n && EXCLUDED_MODERATION.includes(n)) hits.add(n);
  }
  return { safe: hits.size === 0, hits: [...hits] };
}

export type SensitiveCategory = 'card' | 'ssn' | 'bank' | 'id' | 'credentials' | 'medical';

/** Luhn checksum for 13–19 digit strings. */
export function luhnValid(digits: string): boolean {
  if (!/^\d{13,19}$/.test(digits)) return false;
  let sum = 0;
  let dbl = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let d = Number(digits[i]);
    if (dbl) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    dbl = !dbl;
  }
  return sum % 10 === 0;
}

const KEYWORDS: Record<Exclude<SensitiveCategory, 'card' | 'ssn'>, RegExp> = {
  bank: /\b(account\s*(number|no\.?|#)|acct\.?\s*(number|no\.?|#)?|routing\s*(number|no\.?)?|iban|sort\s*code|swift\s*code|available\s*balance|current\s*balance|account\s*balance|wire\s*transfer)\b/i,
  id: /\b(driver'?s?\s*licen[cs]e|licen[cs]e\s*(no\.?|number|#)|passport\s*(no\.?|number)?|date\s*of\s*birth|\bdob\b|social\s*security|identification\s*card|national\s*id|state\s*id)\b/i,
  credentials: /\b(password|passcode|pass\s*word|verification\s*code|security\s*code|one[-\s]?time\s*(pass(word|code)?|code)|\botp\b|2fa|two[-\s]factor|recovery\s*(code|phrase|key)|seed\s*phrase|\bpin\b\s*(code|number)?|api\s*key|secret\s*key)\b/i,
  medical: /\b(diagnosis|diagnosed|prescription|\brx\b|patient\s*(name|id)?|medical\s*record|\bmrn\b|lab\s*results?|test\s*results?|medication|dosage|insurance\s*(member|id|policy))\b/i,
};

/** Rule-based sensitive-text check. Returns the categories that hit. */
export function sensitiveTextRules(text: string): SensitiveCategory[] {
  const hits = new Set<SensitiveCategory>();
  // Card numbers: 13–19 digits, optionally separated by single spaces/dashes.
  for (const m of text.matchAll(/(?:\d[ -]?){12,18}\d/g)) {
    if (luhnValid(m[0].replace(/[ -]/g, ''))) hits.add('card');
  }
  if (/\b\d{3}-\d{2}-\d{4}\b/.test(text)) hits.add('ssn');
  if (/\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){3,7}\b/.test(text)) hits.add('bank'); // IBAN-like
  for (const [cat, re] of Object.entries(KEYWORDS)) if (re.test(text)) hits.add(cat as SensitiveCategory);
  return [...hits];
}

/** Text worth an LLM second opinion: enough words that rules could have missed something. */
export const isTextHeavy = (text: string) => text.split(/\s+/).filter((w) => /[a-z0-9]/i.test(w)).length >= 12;
