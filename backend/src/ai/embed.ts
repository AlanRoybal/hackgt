// Titan Multimodal Embeddings G1 (1024 dims). Image and text share one vector space.
import { MODELS, invokeJson } from './bedrock.js';

export const EMBED_DIMS = 1024;

export async function embedText(text: string): Promise<number[]> {
  const r = await invokeJson(MODELS.embed, {
    inputText: text.slice(0, 1000),
    embeddingConfig: { outputEmbeddingLength: EMBED_DIMS },
  });
  return r.embedding;
}

/** Embeds an image, optionally fused with its caption for better text→image retrieval. */
export async function embedImage(jpeg: Buffer, caption?: string): Promise<number[]> {
  const r = await invokeJson(MODELS.embed, {
    inputImage: jpeg.toString('base64'),
    ...(caption ? { inputText: caption.slice(0, 1000) } : {}),
    embeddingConfig: { outputEmbeddingLength: EMBED_DIMS },
  });
  return r.embedding;
}

export function cosine(a: number[], b: number[]): number {
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (Math.sqrt(na) * Math.sqrt(nb) || 1);
}
