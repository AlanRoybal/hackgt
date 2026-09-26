// S3 ObjectCreated → safety → caption → embedding → S3 Vectors (SPEC PHO-2, PHO-3).
import type { S3Event } from 'aws-lambda';
import { captionImage } from '../ai/caption.js';
import { embedImage } from '../ai/embed.js';
import { get, update } from '../lib/db.js';
import { env } from '../lib/env.js';
import { K } from '../lib/keys.js';
import { emitLatency, stopwatch } from '../lib/metrics.js';
import { checkPhotoSafety } from '../lib/photoSafety.js';
import { deleteObject, getObjectBytes } from '../lib/s3.js';
import { putPhotoVector, vectorKey } from '../lib/vectors.js';

export async function indexPhoto(s3Key: string) {
  const m = /^photos\/([^/]+)\/([^/]+)\.jpg$/.exec(s3Key);
  if (!m) return;
  const [, userId, assetHash] = m;
  const item = await get(K.photo(userId, assetHash));
  if (!item) {
    await deleteObject(s3Key).catch(() => {}); // uploads must be announced first
    return;
  }
  const sw = stopwatch();
  try {
    const safety = await checkPhotoSafety({ S3Object: { Bucket: env.bucket, Name: s3Key } });
    sw.lap('safety');
    if (!safety.safe) {
      await update(K.photo(userId, assetHash), {
        status: 'excluded',
        exclusionReason: safety.reason,
        labels: safety.labels,
        indexedAt: new Date().toISOString(),
      });
      await deleteObject(s3Key).catch(() => {});
      return;
    }
    const bytes = await getObjectBytes(s3Key);
    const caption = await captionImage(bytes);
    sw.lap('caption');
    const embedding = await embedImage(bytes, [caption, item.place].filter(Boolean).join('. '));
    sw.lap('embed');
    const vk = vectorKey(userId, assetHash);
    await putPhotoVector(vk, embedding, {
      userId,
      takenAt: Math.floor(Date.parse(item.takenAt) / 1000),
      place: item.place,
      caption,
    });
    sw.lap('vector');
    await update(K.photo(userId, assetHash), {
      status: 'indexed',
      caption,
      labels: safety.labels,
      vectorKey: vk,
      indexedAt: new Date().toISOString(),
    });
    emitLatency(sw.total(), { pipeline: 'photoIndex' });
  } catch (e) {
    console.error('index failed', s3Key, e);
    await update(K.photo(userId, assetHash), { status: 'failed', exclusionReason: String((e as any)?.name ?? 'error') });
  }
}

export const handler = async (event: S3Event) => {
  for (const r of event.Records) await indexPhoto(decodeURIComponent(r.s3.object.key.replace(/\+/g, ' ')));
};
