// Bedrock helpers. Only Amazon first-party models (credit-eligible, D-12).
import {
  BedrockRuntimeClient,
  ConverseCommand,
  InvokeModelCommand,
  type ContentBlock,
  type Message,
} from '@aws-sdk/client-bedrock-runtime';

export const MODELS = {
  text: 'amazon.nova-lite-v1:0',
  embed: 'amazon.titan-embed-image-v1',
  image: 'amazon.nova-canvas-v1:0',
} as const;

export const bedrock = new BedrockRuntimeClient({ region: process.env.AWS_REGION ?? 'us-east-1' });

export async function converse(opts: {
  system: string;
  messages: Message[];
  maxTokens?: number;
  temperature?: number;
}): Promise<string> {
  const r = await bedrock.send(
    new ConverseCommand({
      modelId: MODELS.text,
      system: [{ text: opts.system }],
      messages: opts.messages,
      inferenceConfig: { maxTokens: opts.maxTokens ?? 300, temperature: opts.temperature ?? 0 },
    }),
  );
  return (r.output?.message?.content ?? []).map((c: ContentBlock) => ('text' in c ? c.text : '')).join('');
}

/** Extracts the first JSON object from model text (tolerates code fences and chatter). */
export function extractJson<T = any>(text: string): T | undefined {
  // Small models sometimes write yes/no for booleans.
  const cleaned = text
    .replace(/```(?:json)?/g, '')
    .replace(/:\s*yes\b/gi, ': true')
    .replace(/:\s*no\b/gi, ': false');
  const start = cleaned.indexOf('{');
  if (start < 0) return undefined;
  let depth = 0;
  let inStr = false;
  let esc = false;
  for (let i = start; i < cleaned.length; i++) {
    const ch = cleaned[i];
    if (inStr) {
      if (esc) esc = false;
      else if (ch === '\\') esc = true;
      else if (ch === '"') inStr = false;
      continue;
    }
    if (ch === '"') inStr = true;
    else if (ch === '{') depth++;
    else if (ch === '}' && --depth === 0) {
      try {
        return JSON.parse(cleaned.slice(start, i + 1));
      } catch {
        return undefined;
      }
    }
  }
  return undefined;
}

export async function invokeJson(modelId: string, body: unknown): Promise<any> {
  const r = await bedrock.send(
    new InvokeModelCommand({ modelId, contentType: 'application/json', accept: 'application/json', body: JSON.stringify(body) }),
  );
  return JSON.parse(new TextDecoder().decode(r.body));
}
