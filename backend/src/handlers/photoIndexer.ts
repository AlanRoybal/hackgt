// S3 ObjectCreated → safety → caption → embedding → S3 Vectors (SPEC PHO-2, PHO-3, VID-2).
import type { S3Event } from 'aws-lambda';
import { captionImage, captionVideo } from '../ai/caption.js';
import { embedImage, embedText } from '../ai/embed.js';
import { get, isConditionalFailure, update } from '../lib/db.js';
import { env } from '../lib/env.js';
import { K } from '../lib/keys.js';
import { MAX_VIDEO_CAPTION_BYTES, mediaTypeOf } from '../lib/media.js';
import { emitLatency, stopwatch } from '../lib/metrics.js';
import { checkPhotoSafety } from '../lib/photoSafety.js';
import { deleteObject, getObjectBytes, objectSize } from '../lib/s3.js';
import { putPhotoVector, vectorKey } from '../lib/vectors.js';

/** A claim older than this belongs to a crashed run and can be retaken. */
const CLAIM_STALE_MS = 5 * 60_000;

export async function indexPhoto(s3Key: string) {
  const m = /^photos\/([^/]+)\/([^/]+)\.(jpg|mp4)$/.exec(s3Key);
  if (!m) return;
  const [, userId, assetHash, ext] = m;
  const item = await get(K.photo(userId, assetHash));
  const video = mediaTypeOf(item) === 'video';
  if (!item || (ext === 'mp4' && !video)) {
    await deleteObject(s3Key).catch(() => {}); // uploads must be announced first
    return;
  }
  if (video) {
    // The poster and the clip upload separately; whichever lands second starts indexing.
    const [poster, clip] = await Promise.all([objectSize(item.s3Key), objectSize(item.videoKey)]);
    if (poster === undefined || clip === undefined) return;
    try {
      await update(K.photo(userId, assetHash), { indexingAt: Date.now() }, {
        condition: 'attribute_not_exists(indexingAt) OR indexingAt < :stale',
        values: { ':stale': Date.now() - CLAIM_STALE_MS },
      });
    } catch (e) {
      if (isConditionalFailure(e)) return; // both uploads landed together; the other invocation has it
      throw e;
    }
  }
  const sw = stopwatch();
  const dropMedia = () => Promise.all([deleteObject(item.s3Key), item.videoKey ? deleteObject(item.videoKey) : undefined]).catch(() => {});
  const exclude = async (reason: string | undefined, labels: string[]) => {
    await update(K.photo(userId, assetHash), { status: 'excluded', exclusionReason: reason, labels, indexedAt: new Date().toISOString() });
    await dropMedia();
  };
  try {
    // Videos are screened on their poster frame with the same rules as photos, then by Nova on the whole clip.
    const safety = await checkPhotoSafety({ S3Object: { Bucket: env.bucket, Name: item.s3Key } });
    sw.lap('safety');
    if (!safety.safe) return await exclude(safety.reason, safety.labels);
    const bytes = await getObjectBytes(item.s3Key);
    let caption: string | undefined;
    if (video && (await objectSize(item.videoKey))! <= MAX_VIDEO_CAPTION_BYTES) {
      const clip = await captionVideo(await getObjectBytes(item.videoKey)).catch((e) => {
        console.warn('video caption failed', s3Key, (e as Error).name);
        return undefined;
      });
      if (clip?.sensitive) return await exclude('llm:video', safety.labels);
      caption = clip?.caption;
    }
    caption ??= await captionImage(bytes);
    sw.lap('caption');
    // Image-only embedding: fusing the caption lowered top-1 from 1.00 to 0.95 in evals/retrieval (D-105).
    // A video embeds its poster frame; its caption (from the whole clip) goes to the caption index.
    const embedding = await embedImage(bytes);
    sw.lap('embed');
    const vk = vectorKey(userId, assetHash);
    const meta = {
      userId,
      takenAt: Math.floor(Date.parse(item.takenAt) / 1000),
      place: item.place,
      caption,
      mediaType: mediaTypeOf(item),
    };
    await putPhotoVector(vk, embedding, meta);
    // A separate caption index adds lexical/event recall without changing the image-only index.
    if (env.captionVectorIndex) await putPhotoVector(vk, await embedText(caption), meta, env.captionVectorIndex);
    sw.lap('vector');
    await update(K.photo(userId, assetHash), {
      status: 'indexed',
      caption,
      labels: safety.labels,
      vectorKey: vk,
      captionVectorKey: env.captionVectorIndex ? vk : undefined,
      indexedAt: new Date().toISOString(),
    });
    emitLatency(sw.total(), { pipeline: video ? 'videoIndex' : 'photoIndex' });
  } catch (e) {
    console.error('index failed', s3Key, e);
    await update(K.photo(userId, assetHash), { status: 'failed', exclusionReason: String((e as any)?.name ?? 'error') });
  }
}

export const handler = async (event: S3Event) => {
  for (const r of event.Records) await indexPhoto(decodeURIComponent(r.s3.object.key.replace(/\+/g, ' ')));
};
