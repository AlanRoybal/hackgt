// /photos/* — upload URLs, status, deletion for photos and short videos (SPEC PHO-1, PHO-5, PHO-6, VID-1).
import { batchDelete, batchGet, del, get, put, queryPrefix } from '../lib/db.js';
import { bad, router } from '../lib/http.js';
import { K } from '../lib/keys.js';
import { mediaTypeOf, videoDuration } from '../lib/media.js';
import { deleteObject, deletePrefix, photoKey, presignPut, videoKey } from '../lib/s3.js';
import { deletePhotoVectors } from '../lib/vectors.js';
import { getUser } from '../lib/users.js';

const WINDOW_MS = 30 * 86_400_000;
const HASH = /^[A-Za-z0-9_-]{8,128}$/;

export const handler = router({
  'POST /photos/uploads': async ({ userId, body }) => {
    if (!Array.isArray(body.items) || body.items.length > 50) throw bad('invalid_items');
    const user = await getUser(userId);
    const now = Date.now();
    const valid = body.items.filter(
      (i: any) => i && typeof i.assetHash === 'string' && HASH.test(i.assetHash) && !Number.isNaN(Date.parse(i.takenAt)) && videoDuration(i) !== undefined,
    );
    const skipped: string[] = body.items.filter((i: any) => !valid.includes(i)).map((i: any) => String(i?.assetHash ?? ''));
    if (!user.settings.photoIndexing) return { uploads: [], skipped: body.items.map((i: any) => String(i?.assetHash ?? '')) };
    const existing = new Map(
      (await batchGet(valid.map((i: any) => K.photo(userId, i.assetHash)))).map((p) => [p.assetHash, p]),
    );
    const uploads = [];
    for (const i of valid) {
      const takenAt = Date.parse(i.takenAt);
      const prev = existing.get(i.assetHash);
      const tooOld = now - takenAt > WINDOW_MS || takenAt > now + 86_400_000;
      const screenshotBlocked = i.isScreenshot === true && !user.settings.includeScreenshots;
      const done = prev && (prev.status === 'indexed' || prev.status === 'excluded' || (prev.status === 'pending' && now - Date.parse(prev.createdAt) < 3_600_000));
      if (tooOld || screenshotBlocked || done) {
        skipped.push(i.assetHash);
        continue;
      }
      const s3Key = photoKey(userId, i.assetHash);
      const durationMs = videoDuration(i);
      // A video uploads its poster frame to `s3Key` and the clip to `videoKey`; indexing waits for both.
      const clipKey = durationMs ? videoKey(userId, i.assetHash) : undefined;
      await put({
        ...K.photo(userId, i.assetHash),
        assetHash: i.assetHash,
        userId,
        s3Key,
        takenAt: new Date(takenAt).toISOString(),
        place: typeof i.place === 'string' ? i.place.slice(0, 120) : undefined,
        isScreenshot: i.isScreenshot === true,
        mediaType: durationMs ? 'video' : 'photo',
        videoKey: clipKey,
        durationMs: durationMs ?? undefined,
        width: Number(i.width) || undefined,
        height: Number(i.height) || undefined,
        status: 'pending',
        labels: [],
        createdAt: new Date(now).toISOString(),
        ttl: Math.floor(takenAt / 1000) + 31 * 86_400,
      });
      uploads.push({
        assetHash: i.assetHash,
        uploadUrl: await presignPut(s3Key),
        videoUploadUrl: clipKey ? await presignPut(clipKey, 3600, 'video/mp4') : undefined,
      });
    }
    return { uploads, skipped };
  },

  'GET /photos/status': async ({ userId }) => {
    const photos = await queryPrefix(`USER#${userId}`, 'PHOTO#');
    const count = (s: string) => photos.filter((p) => p.status === s).length;
    const last = photos.map((p) => p.indexedAt).filter(Boolean).sort().pop();
    const videos = photos.filter((p) => p.status === 'indexed' && mediaTypeOf(p) === 'video').length;
    return { indexed: count('indexed'), videos, excluded: count('excluded'), pending: count('pending'), failed: count('failed'), lastIndexedAt: last };
  },

  'DELETE /photos/{assetHash}': async ({ userId, params }) => {
    const p = await get(K.photo(userId, params.assetHash));
    if (!p) return;
    if (p.vectorKey) await deletePhotoVectors([p.vectorKey]);
    await deleteObject(p.s3Key).catch(() => {});
    if (p.videoKey) await deleteObject(p.videoKey).catch(() => {});
    await del(K.photo(userId, params.assetHash));
  },

  'DELETE /photos': async ({ userId }) => {
    const photos = await queryPrefix(`USER#${userId}`, 'PHOTO#');
    const vk = photos.map((p) => p.vectorKey).filter(Boolean) as string[];
    if (vk.length) await deletePhotoVectors(vk);
    await deletePrefix(`photos/${userId}/`);
    await batchDelete(photos.map((p) => ({ pk: p.pk, sk: p.sk })));
  },
});
