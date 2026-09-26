// Full account deletion (SPEC ACC-12): items, pair data, calls, S3 objects, vectors, Cognito user.
import { batchDelete, del, queryGsi, queryPartition, type Key } from './db.js';
import { deleteCognitoUser } from './cognito.js';
import { K, pairKey } from './keys.js';
import { avatarKey, deleteObject, deletePrefix } from './s3.js';
import { deletePhotoVectors } from './vectors.js';
import type { UserItem } from './users.js';
import { disconnectWhoop } from './whoop.js';

export async function deleteAccount(user: UserItem): Promise<void> {
  const id = user.id;
  await disconnectWhoop(id);
  const own = await queryPartition(`USER#${id}`);
  const keys: Key[] = own.map((i) => ({ pk: i.pk, sk: i.sk }));

  // Vectors for indexed photos.
  const vectorKeys = own.filter((i) => i.sk.startsWith('PHOTO#') && i.vectorKey).map((i) => i.vectorKey as string);
  if (vectorKeys.length) await deletePhotoVectors(vectorKeys);

  // Friendships (reverse side) and all pair data (messages, topics, summaries, nudges, calls).
  const friendIds = own.filter((i) => i.sk.startsWith('FRIEND#')).map((i) => i.sk.slice('FRIEND#'.length));
  for (const f of friendIds) {
    keys.push(K.friend(f, id));
    const pk = pairKey(id, f);
    const pairItems = await queryPartition(`PAIR#${pk}`);
    keys.push(...pairItems.map((i) => ({ pk: i.pk, sk: i.sk })));
    const byPair = await queryGsi(`PAIR#${pk}`);
    for (const item of byPair) {
      keys.push({ pk: item.pk, sk: item.sk });
      if (item.pk.startsWith('CALL#')) {
        const sub = await queryPartition(item.pk);
        keys.push(...sub.map((i) => ({ pk: i.pk, sk: i.sk })));
      }
    }
  }

  // Outgoing friend requests, WebSocket connections, claims, push log.
  const outgoing = await queryGsi(`FREQOUT#${id}`);
  keys.push(...outgoing.map((i) => ({ pk: i.pk, sk: i.sk })));
  const conns = await queryGsi(`CONNUSER#${id}`);
  keys.push(...conns.map((i) => ({ pk: i.pk, sk: i.sk })));
  if (user.handle) keys.push(K.handle(user.handle));
  if (user.phoneHash) keys.push(K.phone(user.phoneHash));
  const pushLog = await queryPartition(`PUSHLOG#${id}`);
  keys.push(...pushLog.map((i) => ({ pk: i.pk, sk: i.sk })));

  await batchDelete(keys);
  await deletePrefix(`photos/${id}/`);
  await deleteObject(avatarKey(id)).catch(() => {});
  try {
    await deleteCognitoUser(user.username);
  } catch (e) {
    if ((e as any)?.name !== 'UserNotFoundException') throw e;
  }
  await del(K.user(id)).catch(() => {});
}
