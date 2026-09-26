// Daily: remove photos older than 30 days from the vector index and table (SPEC PHO-4).
import { batchDelete, queryGsi, queryPrefix } from '../lib/db.js';
import { deleteVectors, listAllVectors } from '../lib/vectors.js';

export const cutoffSec = (now: number) => Math.floor((now - 30 * 86_400_000) / 1000);

export async function sweep(now = Date.now()) {
  const cutoff = cutoffSec(now);
  const stale: string[] = [];
  for await (const v of listAllVectors()) if (Number(v.metadata.takenAt) < cutoff) stale.push(v.key);
  await deleteVectors(stale);

  let items = 0;
  const users = await queryGsi('USERS');
  for (const u of users) {
    const old = (await queryPrefix(`USER#${u.id}`, 'PHOTO#')).filter((p) => Date.parse(p.takenAt) / 1000 < cutoff);
    items += old.length;
    await batchDelete(old.map((p) => ({ pk: p.pk, sk: p.sk })));
  }
  // S3 objects expire through the bucket lifecycle rule (31 days).
  console.log(JSON.stringify({ msg: 'sweep', vectorsDeleted: stale.length, itemsDeleted: items }));
  return { vectorsDeleted: stale.length, itemsDeleted: items };
}

export const handler = async () => sweep();
