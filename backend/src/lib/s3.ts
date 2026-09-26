// S3 media helpers: presigned URLs and bulk deletes.
import {
  DeleteObjectCommand,
  DeleteObjectsCommand,
  GetObjectCommand,
  ListObjectsV2Command,
  PutObjectCommand,
  S3Client,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { env } from './env.js';

export const s3 = new S3Client({});

export const presignGet = (key: string, expiresIn: number) =>
  getSignedUrl(s3, new GetObjectCommand({ Bucket: env.bucket, Key: key }), { expiresIn });

export const presignPut = (key: string, expiresIn = 900) =>
  getSignedUrl(s3, new PutObjectCommand({ Bucket: env.bucket, Key: key, ContentType: 'image/jpeg' }), { expiresIn });

export async function getObjectBytes(key: string): Promise<Buffer> {
  const r = await s3.send(new GetObjectCommand({ Bucket: env.bucket, Key: key }));
  return Buffer.from(await r.Body!.transformToByteArray());
}

export const deleteObject = (key: string) => s3.send(new DeleteObjectCommand({ Bucket: env.bucket, Key: key }));

export async function deletePrefix(prefix: string): Promise<number> {
  let n = 0;
  let token: string | undefined;
  do {
    const r = await s3.send(new ListObjectsV2Command({ Bucket: env.bucket, Prefix: prefix, ContinuationToken: token }));
    const objs = (r.Contents ?? []).map((o) => ({ Key: o.Key! }));
    if (objs.length) {
      await s3.send(new DeleteObjectsCommand({ Bucket: env.bucket, Delete: { Objects: objs } }));
      n += objs.length;
    }
    token = r.IsTruncated ? r.NextContinuationToken : undefined;
  } while (token);
  return n;
}

export const avatarKey = (userId: string) => `avatars/${userId}.jpg`;
export const photoKey = (userId: string, assetHash: string) => `photos/${userId}/${assetHash}.jpg`;
