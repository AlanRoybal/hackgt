// LLM second opinion for text-heavy photos the rules didn't flag (SPEC PHO-2).
import { converse, extractJson } from './bedrock.js';

export const SENSITIVE_SYSTEM = `You check text extracted (OCR) from a personal photo before it may be shown to a friend on a video call.
Mark it sensitive if it shows any of: payment card or bank/account details, balances or transactions, government ID or license details, passwords, PINs, login or verification codes, recovery phrases, medical records/diagnoses/prescriptions, insurance IDs, or someone's full home address with other personal data.
Menus, signs, posters, book pages, product labels, handwritten notes without the above, chats about everyday things are NOT sensitive.
Reply JSON only: {"sensitive": boolean, "category": "card|bank|id|credentials|medical|address|none"}`;

export async function llmSensitiveCheck(ocrText: string): Promise<{ sensitive: boolean; category: string }> {
  const text = await converse({
    system: SENSITIVE_SYSTEM,
    maxTokens: 60,
    messages: [{ role: 'user', content: [{ text: `OCR text:\n"""${ocrText.slice(0, 3000)}"""\n\nJSON:` }] }],
  });
  const j = extractJson<{ sensitive: boolean; category: string }>(text);
  // Fail closed: if the model's answer can't be parsed, treat the photo as sensitive.
  if (!j || typeof j.sensitive !== 'boolean') return { sensitive: true, category: 'unparsed' };
  return { sensitive: j.sensitive, category: j.category ?? 'none' };
}
