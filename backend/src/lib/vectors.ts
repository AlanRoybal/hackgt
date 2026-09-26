// S3 Vectors index for photo embeddings (SPEC §3.3).
import {
  DeleteVectorsCommand,
  ListVectorsCommand,
  PutVectorsCommand,
  QueryVectorsCommand,
  S3VectorsClient,
} from '@aws-sdk/client-s3vectors';
import { env } from './env.js';

const client = new S3VectorsClient({});

export const vectorKey = (userId: string, assetHash: string) => `${userId}#${assetHash}`;

export interface PhotoVectorMeta {
  userId: string;
  takenAt: number; // epoch seconds
  place?: string;
  caption?: string;
}

export async function putPhotoVector(key: string, data: number[], meta: PhotoVectorMeta, index = env.vectorIndex) {
  const metadata: Record<string, string | number> = { userId: meta.userId, takenAt: meta.takenAt };
  if (meta.place) metadata.place = meta.place;
  if (meta.caption) metadata.caption = meta.caption.slice(0, 500);
  await client.send(
    new PutVectorsCommand({
      vectorBucketName: env.vectorBucket,
      indexName: index,
      vectors: [{ key, data: { float32: data }, metadata }],
    }),
  );
}

export interface VectorHit {
  key: string;
  similarity: number;
  metadata: Record<string, any>;
}

export async function queryPhotos(
  userId: string,
  vector: number[],
  opts: { topK?: number; fromSec?: number; toSec?: number; index?: string } = {},
): Promise<VectorHit[]> {
  const clauses: Record<string, unknown>[] = [{ userId: { $eq: userId } }];
  if (opts.fromSec !== undefined) clauses.push({ takenAt: { $gte: opts.fromSec } });
  if (opts.toSec !== undefined) clauses.push({ takenAt: { $lte: opts.toSec } });
  const r = await client.send(
    new QueryVectorsCommand({
      vectorBucketName: env.vectorBucket,
      indexName: opts.index ?? env.vectorIndex,
      queryVector: { float32: vector },
      topK: opts.topK ?? 5,
      filter: (clauses.length === 1 ? clauses[0] : { $and: clauses }) as any,
      returnDistance: true,
      returnMetadata: true,
    }),
  );
  // Cosine distance → similarity.
  return (r.vectors ?? []).map((v) => ({
    key: v.key!,
    similarity: 1 - (v.distance ?? 1),
    metadata: (v.metadata ?? {}) as Record<string, any>,
  }));
}

/** Caption search is additive. Old deployments keep working until the second index exists. */
export async function queryCaptionPhotos(
  userId: string,
  vector: number[],
  opts: { topK?: number; fromSec?: number; toSec?: number } = {},
): Promise<VectorHit[]> {
  if (!env.captionVectorIndex) return [];
  return queryPhotos(userId, vector, { ...opts, index: env.captionVectorIndex });
}

export async function deleteVectors(keys: string[], index = env.vectorIndex) {
  for (let i = 0; i < keys.length; i += 500) {
    const chunk = keys.slice(i, i + 500);
    if (chunk.length) {
      await client.send(new DeleteVectorsCommand({ vectorBucketName: env.vectorBucket, indexName: index, keys: chunk }));
    }
  }
}

export async function deletePhotoVectors(keys: string[]) {
  await deleteVectors(keys);
  if (env.captionVectorIndex) await deleteVectors(keys, env.captionVectorIndex);
}

/** Iterates every vector with metadata (used by the daily sweep). */
export async function* listAllVectors(index = env.vectorIndex): AsyncGenerator<{ key: string; metadata: Record<string, any> }> {
  let nextToken: string | undefined;
  do {
    const r = await client.send(
      new ListVectorsCommand({ vectorBucketName: env.vectorBucket, indexName: index, returnMetadata: true, nextToken }),
    );
    for (const v of r.vectors ?? []) yield { key: v.key!, metadata: (v.metadata ?? {}) as Record<string, any> };
    nextToken = r.nextToken;
  } while (nextToken);
}
