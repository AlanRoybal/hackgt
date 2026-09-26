// One-time migration after deploying the photo-captions S3 Vector index.
// Example:
// AWS_PROFILE=nudge-dev TABLE_NAME=Nudge-dev VECTOR_BUCKET=nudge-vectors-dev-724772092774 \
// CAPTION_VECTOR_INDEX=photo-captions npx tsx scripts/backfill-caption-vectors.ts
import { embedText } from '../src/ai/embed.js';
import { queryGsi, queryPrefix, update } from '../src/lib/db.js';
import { K } from '../src/lib/keys.js';
import { putPhotoVector, vectorKey } from '../src/lib/vectors.js';
import { env } from '../src/lib/env.js';

if (!env.captionVectorIndex) throw new Error('set CAPTION_VECTOR_INDEX before running this migration');

let indexed = 0;
const users = await queryGsi('USERS');
for (const user of users) {
  const photos = await queryPrefix(`USER#${user.id}`, 'PHOTO#');
  for (const photo of photos) {
    if (photo.status !== 'indexed' || !photo.caption || photo.captionVectorKey) continue;
    const key = photo.vectorKey ?? vectorKey(user.id, photo.assetHash);
    await putPhotoVector(key, await embedText(photo.caption), {
      userId: user.id,
      takenAt: Math.floor(Date.parse(photo.takenAt) / 1000),
      place: photo.place,
      caption: photo.caption,
    }, env.captionVectorIndex);
    await update(K.photo(user.id, photo.assetHash), { captionVectorKey: key });
    indexed++;
  }
}
console.log(JSON.stringify({ indexed, index: env.captionVectorIndex }));
