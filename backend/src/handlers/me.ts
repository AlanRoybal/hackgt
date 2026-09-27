// /me/*, /handles/{handle}, /transcribe/config, /telemetry.
import { createHash } from 'node:crypto';
import { checkHandle } from '../engine/handles.js';
import { stepDown } from '../engine/frequency.js';
import { becameBusyAt, mergeBusyBlocks } from '../engine/overlap.js';
import { del, get, isConditionalFailure, put, update } from '../lib/db.js';
import { confirmPhone, getPhone, startPhoneVerification } from '../lib/cognito.js';
import { deleteAccount } from '../lib/deleteAccount.js';
import { env } from '../lib/env.js';
import { bad, conflict, notFound, Res, router } from '../lib/http.js';
import { K } from '../lib/keys.js';
import { emitLatency } from '../lib/metrics.js';
import { avatarKey, presignPut } from '../lib/s3.js';
import { isValidTimeZone, validateSettingsPatch } from '../lib/settings.js';
import { getUser, meResponse, withDefaults, type UserItem } from '../lib/users.js';

const E164 = /^\+[1-9]\d{6,14}$/;
export const phoneHash = (e164: string) => createHash('sha256').update(e164).digest('hex');

async function handleAvailable(raw: string, selfId?: string) {
  const c = checkHandle(raw);
  if (!c.ok) return { available: false, reason: c.reason };
  const claim = await get(K.handle(c.handle));
  if (claim && claim.userId !== selfId) return { available: false, reason: 'taken' as const };
  return { available: true };
}

/** Stores a verified phone's hash claim (moving it from any previous owner). */
export async function claimPhone(user: UserItem, e164: string) {
  const hash = phoneHash(e164);
  const prev = await get(K.phone(hash));
  if (prev && prev.userId !== user.id) await update({ pk: `USER#${prev.userId}`, sk: 'PROFILE' }, { phoneHash: undefined, phoneVerified: false }).catch(() => {});
  if (user.phoneHash && user.phoneHash !== hash) await del(K.phone(user.phoneHash)).catch(() => {});
  await put({ ...K.phone(hash), userId: user.id });
  return (await update(K.user(user.id), { phoneHash: hash, phoneVerified: true })) as UserItem;
}

export const handler = router({
  'GET /me': async ({ userId }) => meResponse(await getUser(userId)),

  'PATCH /me': async ({ userId, body }) => {
    const u = await getUser(userId);
    const set: Record<string, unknown> = {};
    if (body.displayName !== undefined) {
      if (typeof body.displayName !== 'string' || body.displayName.length > 60) throw bad('invalid_display_name');
      set.displayName = body.displayName.trim();
    }
    if (body.tz !== undefined) {
      if (!isValidTimeZone(body.tz)) throw bad('invalid_tz');
      set.tz = body.tz;
    }
    if (body.avatarKey !== undefined) {
      if (body.avatarKey !== null && body.avatarKey !== avatarKey(userId)) throw bad('invalid_avatar_key');
      set.avatarKey = body.avatarKey ?? undefined;
    }
    const s = validateSettingsPatch(body.settings);
    if (Object.keys(s).length) {
      set.settings = { ...withDefaults(u.settings), ...s };
      if (s.frequency) set.frequencyBeforeLess = undefined; // an explicit choice clears "Undo"
    }
    if (!Object.keys(set).length) return meResponse(u);
    return meResponse((await update(K.user(userId), set)) as UserItem);
  },

  'POST /me/tos': async ({ userId, body }) => {
    if (body.version !== env.currentTosVersion) throw bad('tos_version_mismatch', `current version is ${env.currentTosVersion}`);
    return meResponse((await update(K.user(userId), { tosVersion: body.version, tosAcceptedAt: new Date().toISOString() })) as UserItem);
  },

  'GET /handles/{handle}': async ({ userId, params }) => handleAvailable(decodeURIComponent(params.handle ?? ''), userId),

  'PUT /me/handle': async ({ userId, body }) => {
    const c = checkHandle(String(body.handle ?? ''));
    if (!c.ok) throw bad(c.reason === 'reserved' ? 'handle_reserved' : 'handle_invalid');
    const u = await getUser(userId);
    if (u.handle === c.handle) return meResponse(u);
    try {
      await put({ ...K.handle(c.handle), userId }, 'attribute_not_exists(pk) OR userId = :me', { ':me': userId });
    } catch (e) {
      if (isConditionalFailure(e)) throw conflict('handle_taken');
      throw e;
    }
    if (u.handle) await del(K.handle(u.handle)).catch(() => {});
    return meResponse((await update(K.user(userId), { handle: c.handle, gsi1pk: 'USERS', gsi1sk: c.handle })) as UserItem);
  },

  'POST /me/avatar': async ({ userId }) => ({ uploadUrl: await presignPut(avatarKey(userId), 900), avatarKey: avatarKey(userId) }),

  'POST /me/phone': async ({ accessToken, body }) => {
    if (typeof body.phone !== 'string' || !E164.test(body.phone)) throw bad('invalid_phone');
    await startPhoneVerification(accessToken, body.phone);
    return { codeSent: true };
  },

  'POST /me/phone/verify': async ({ userId, username, accessToken, body }) => {
    if (typeof body.code !== 'string' || !/^\d{4,8}$/.test(body.code)) throw bad('code_mismatch');
    await confirmPhone(accessToken, body.code);
    const { phone, verified } = await getPhone(username);
    if (!phone || !verified) throw bad('code_mismatch');
    return meResponse(await claimPhone(await getUser(userId), phone));
  },

  'DELETE /me/phone': async ({ userId }) => {
    const u = await getUser(userId);
    if (u.phoneHash) await del(K.phone(u.phoneHash)).catch(() => {});
    return meResponse((await update(K.user(userId), { phoneHash: undefined, phoneVerified: false })) as UserItem);
  },

  'POST /me/devices': async ({ userId, body }) => {
    if (typeof body.deviceId !== 'string' || !body.deviceId || body.deviceId.length > 100) throw bad('invalid_device');
    if (body.apnsEnv !== 'sandbox' && body.apnsEnv !== 'production') throw bad('invalid_apns_env');
    const tok = (t: unknown) => (typeof t === 'string' && /^[0-9a-fA-F]{32,200}$/.test(t) ? t.toLowerCase() : undefined);
    const existing = await get(K.device(userId, body.deviceId));
    await put({
      ...K.device(userId, body.deviceId),
      deviceId: body.deviceId,
      apnsToken: tok(body.apnsToken) ?? existing?.apnsToken,
      voipToken: tok(body.voipToken) ?? existing?.voipToken,
      apnsEnv: body.apnsEnv,
      appVersion: typeof body.appVersion === 'string' ? body.appVersion.slice(0, 40) : undefined,
      lastSeenAt: new Date().toISOString(),
    });
  },

  'PUT /me/availability': async ({ userId, body }) => {
    if (!Array.isArray(body.busyBlocks) || body.busyBlocks.length > 2000) throw bad('invalid_busy_blocks');
    const blocks = body.busyBlocks
      .filter((b: any) => b && typeof b.start === 'string' && typeof b.end === 'string')
      .map((b: any) => ({ start: b.start, end: b.end }));
    const syncedAt = typeof body.syncedAt === 'string' && !Number.isNaN(Date.parse(body.syncedAt)) ? body.syncedAt : new Date().toISOString();
    const existing = await get(K.avail(userId));
    // Clients only send blocks from now on, so remember when a block that has begun started before it drops out.
    const merged = mergeBusyBlocks(blocks);
    const busyStart = becameBusyAt({ busyBlocks: [...(existing?.busyBlocks ?? []), ...merged], lastBusyStart: existing?.lastBusyStart }, Date.now());
    const lastBusyStart = busyStart === undefined ? undefined : new Date(busyStart).toISOString();
    await put({ ...(existing ?? {}), ...K.avail(userId), busyBlocks: merged, syncedAt, source: body.source ?? 'apple', lastBusyStart });
    if (isValidTimeZone(body.tz)) await update(K.user(userId), { tz: body.tz });
  },

  'PUT /me/context': async ({ userId, body }) => {
    const set: Record<string, unknown> = {};
    const at = (v: any) => (typeof v?.at === 'string' && !Number.isNaN(Date.parse(v.at)) ? v.at : new Date().toISOString());
    if (body.focus && typeof body.focus.isFocused === 'boolean') set.focus = { isFocused: body.focus.isFocused, at: at(body.focus) };
    if (body.driving && typeof body.driving.isDriving === 'boolean') set.driving = { isDriving: body.driving.isDriving, at: at(body.driving) };
    if (!Object.keys(set).length) throw bad('empty_context');
    await update(K.avail(userId), set);
  },

  'POST /me/frequency/less': async ({ userId }) => {
    const u = await getUser(userId);
    const next = stepDown(u.settings.frequency);
    if (next === u.settings.frequency) return meResponse(u);
    return meResponse(
      (await update(K.user(userId), { settings: { ...u.settings, frequency: next }, frequencyBeforeLess: u.settings.frequency })) as UserItem,
    );
  },

  'POST /me/frequency/undo': async ({ userId }) => {
    const u = await getUser(userId);
    if (!u.frequencyBeforeLess) return meResponse(u);
    return meResponse(
      (await update(K.user(userId), { settings: { ...u.settings, frequency: u.frequencyBeforeLess }, frequencyBeforeLess: undefined })) as UserItem,
    );
  },

  'DELETE /me': async ({ userId }) => {
    await deleteAccount(await getUser(userId));
    return new Res(202, { deleted: true });
  },

  'GET /transcribe/config': async () => ({
    identityPoolId: env.identityPoolId,
    region: env.region,
    userPoolProviderName: `cognito-idp.${env.region}.amazonaws.com/${env.userPoolId}`,
  }),

  'POST /telemetry': async ({ userId, body }) => {
    if (!env.isDev) throw notFound();
    const events = Array.isArray(body.events) ? body.events.slice(0, 50) : [];
    for (const e of events) {
      if (typeof e?.name === 'string' && typeof e?.ms === 'number') {
        emitLatency({ [e.name.slice(0, 40)]: e.ms }, { pipeline: 'client' }, { userId, callId: e.callId });
      }
    }
  },
});
