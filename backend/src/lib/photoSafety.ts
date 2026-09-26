// Full photo safety decision: Rekognition moderation + OCR rules + LLM second opinion (SPEC PHO-2).
import { DetectModerationLabelsCommand, DetectTextCommand, RekognitionClient, type Image } from '@aws-sdk/client-rekognition';
import { llmSensitiveCheck } from '../ai/sensitive.js';
import { isTextHeavy, moderationVerdict, sensitiveTextRules } from '../engine/safety.js';

const rek = new RekognitionClient({});

export interface SafetyResult {
  safe: boolean;
  reason?: string;
  labels: string[];
  ocrText: string;
}

/** Decision given raw detector outputs; `llm` is injectable for tests. */
export async function decideSafety(
  moderation: { Name?: string; ParentName?: string; Confidence?: number }[],
  ocrText: string,
  llm: (text: string) => Promise<{ sensitive: boolean; category: string }> = llmSensitiveCheck,
): Promise<SafetyResult> {
  const labels = moderation.filter((l) => (l.Confidence ?? 0) >= 60).map((l) => l.Name ?? '').filter(Boolean);
  const mv = moderationVerdict(moderation);
  if (!mv.safe) return { safe: false, reason: `moderation:${mv.hits.join(',')}`, labels, ocrText };
  const rules = sensitiveTextRules(ocrText);
  if (rules.length) return { safe: false, reason: `text:${rules.join(',')}`, labels, ocrText };
  if (isTextHeavy(ocrText)) {
    const j = await llm(ocrText);
    if (j.sensitive) return { safe: false, reason: `llm:${j.category}`, labels, ocrText };
  }
  return { safe: true, labels, ocrText };
}

export async function checkPhotoSafety(image: Image): Promise<SafetyResult> {
  const [mod, text] = await Promise.all([
    rek.send(new DetectModerationLabelsCommand({ Image: image, MinConfidence: 50 })),
    rek.send(new DetectTextCommand({ Image: image })),
  ]);
  const ocr = (text.TextDetections ?? [])
    .filter((t) => t.Type === 'LINE')
    .map((t) => t.DetectedText ?? '')
    .join('\n');
  return decideSafety(mod.ModerationLabels ?? [], ocr);
}
