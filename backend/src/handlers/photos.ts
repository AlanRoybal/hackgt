// /photos/* — upload URLs, status, deletion (SPEC PHO-1, PHO-5, PHO-6).
import { batchDelete, batchGet, del, get, put, queryPrefix } from '../lib/db.js';
import { bad, router } from '../lib/http.js';
import { K } from '../lib/keys.js';
import { deleteObject, deletePrefix, photoKey, presignPut } from '../lib/s3.js';
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
      (i: any) => i && typeof i.assetHash === 'string' && HASH.test(i.assetHash) && !Number.isNaN(Date.parse(i.takenAt)),
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
      await put({
        ...K.photo(userId, i.assetHash),
        assetHash: i.assetHash,
        userId,
        s3Key,
        takenAt: new Date(takenAt).toISOString(),
        place: typeof i.place === 'string' ? i.place.slice(0, 120) : undefined,
        isScreenshot: i.isScreenshot === true,
        width: Number(i.width) || undefined,
        height: Number(i.height) || undefined,
        status: 'pending',
        labels: [],
        createdAt: new Date(now).toISOString(),
        ttl: Math.floor(takenAt / 1000) + 31 * 86_400,
      });
      uploads.push({ assetHash: i.assetHash, uploadUrl: await presignPut(s3Key) });
    }
    return { uploads, skipped };
  },

  'GET /photos/status': async ({ userId }) => {
    const photos = await queryPrefix(`USER#${userId}`, 'PHOTO#');
    const count = (s: string) => photos.filter((p) => p.status === s).length;
    const last = photos.map((p) => p.indexedAt).filter(Boolean).sort().pop();
    return { indexed: count('indexed'), excluded: count('excluded'), pending: count('pending'), failed: count('failed'), lastIndexedAt: last };
  },

  'DELETE /photos/{assetHash}': async ({ userId, params }) => {
    const p = await get(K.photo(userId, params.assetHash));
    if (!p) return;
    if (p.vectorKey) await deletePhotoVectors([p.vectorKey]);
    await deleteObject(p.s3Key).catch(() => {});
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
