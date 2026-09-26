// POST /auth/apple, /auth/refresh, /auth/dev (dev only). D-3.
import { GetParameterCommand, SSMClient } from '@aws-sdk/client-ssm';
import { createRemoteJWKSet, jwtVerify } from 'jose';
import { DEFAULT_SETTINGS } from '../engine/types.js';
import { put } from '../lib/db.js';
import { ensureUser, mintTokens, refreshTokens } from '../lib/cognito.js';
import { env } from '../lib/env.js';
import { bad, HttpError, notFound, router } from '../lib/http.js';
import { K } from '../lib/keys.js';
import { findUser, type UserItem } from '../lib/users.js';

const appleJwks = createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'));
let bundleIdPromise: Promise<string> | undefined;

/** Bundle ID used as the Apple token audience; set by scripts/put-apns-secrets.sh. */
function appleAudience(): Promise<string> {
  bundleIdPromise ??= new SSMClient({})
    .send(new GetParameterCommand({ Name: `/nudge/${env.stage}/apple/bundleId` }))
    .then((r) => r.Parameter?.Value ?? 'com.example.nudge')
    .catch(() => 'com.example.nudge');
  return bundleIdPromise;
}

export async function verifyAppleToken(identityToken: string, audience: string) {
  const { payload } = await jwtVerify(identityToken, appleJwks, { issuer: 'https://appleid.apple.com', audience });
  if (!payload.sub) throw new HttpError(401, 'invalid_token');
  return payload;
}

/** Creates the app-level user record on first sign-in. */
async function ensureProfile(sub: string, username: string, displayName?: string): Promise<boolean> {
  const existing = await findUser(sub);
  if (existing) return false;
  const now = new Date().toISOString();
  const user: UserItem = {
    ...K.user(sub),
    id: sub,
    username,
    displayName: displayName?.trim() ?? '',
    tz: 'UTC',
    settings: DEFAULT_SETTINGS,
    createdAt: now,
  };
  try {
    await put(user, 'attribute_not_exists(pk)');
    return true;
  } catch {
    return false;
  }
}

async function signIn(username: string, displayName?: string) {
  const { sub } = await ensureUser(username);
  const isNew = await ensureProfile(sub, username, displayName);
  const t = await mintTokens(username);
  return { ...t, userId: sub, isNew };
}

export const handler = router(
  {
    'POST /auth/apple': async ({ body }) => {
      if (typeof body.identityToken !== 'string') throw bad('missing_token');
      let payload;
      try {
        payload = await verifyAppleToken(body.identityToken, await appleAudience());
      } catch (e) {
        if (e instanceof HttpError) throw e;
        throw new HttpError(401, 'invalid_token', String((e as Error).message));
      }
      const fullName = typeof body.fullName === 'string' ? body.fullName : undefined;
      return signIn(`apple_${payload.sub}`, fullName);
    },
    'POST /auth/refresh': async ({ body }) => {
      if (typeof body.refreshToken !== 'string') throw bad('missing_token');
      const t = await refreshTokens(body.refreshToken);
      return { ...t, userId: String(body.userId ?? ''), isNew: false };
    },
    'POST /auth/dev': async ({ body }) => {
      if (!env.isDev) throw notFound();
      const name = String(body.username ?? '').toLowerCase();
      if (!/^[a-z0-9_]{3,40}$/.test(name)) throw bad('invalid_username');
      return signIn(`dev_${name}`, body.displayName);
    },
  },
  { public: true },
);
