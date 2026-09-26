// Push delivery to all of a user's devices (SPEC §3.9). In dev every push is also written to the push log.
import { del, put, queryPrefix } from './db.js';
import { env } from './env.js';
import { apnsConfig, sendApns, type ApnsEnv, type PushType } from './apns.js';
import { newId } from './keys.js';

export interface Device {
  pk: string;
  sk: string;
  deviceId: string;
  apnsToken?: string;
  voipToken?: string;
  apnsEnv: ApnsEnv;
  appVersion?: string;
  lastSeenAt?: string;
}

export interface PushOptions {
  expiration?: number;
  collapseId?: string;
}

export async function pushToUser(userId: string, type: PushType, payload: Record<string, unknown>, opts: PushOptions = {}) {
  if (env.isDev) {
    const at = new Date().toISOString();
    await put({
      pk: `PUSHLOG#${userId}`,
      sk: `${at}#${newId('p')}`,
      kind: type,
      payload,
      createdAt: at,
      ttl: Math.floor(Date.now() / 1000) + 86_400,
    });
  }
  const cfg = await apnsConfig();
  if (!cfg) {
    // Nothing reaches a device without this, so it's an error rather than a quiet no-op (see scripts/put-apns-secrets.sh).
    console.error(JSON.stringify({ msg: 'push dropped: apns not configured', stage: env.stage, userId, type, payloadType: payload.type }));
    return;
  }
  const devices = await queryPrefix<Device>(`USER#${userId}`, 'DEVICE#');
  await Promise.all(
    devices.map(async (d) => {
      const token = type === 'voip' ? d.voipToken : d.apnsToken;
      if (!token) return;
      const r = await sendApns(cfg, { token, env: d.apnsEnv ?? 'production', type, payload, ...opts });
      if (r.status !== 200) console.warn(JSON.stringify({ msg: 'apns failed', userId, device: d.deviceId, ...r }));
      if (r.status === 410 || r.reason === 'BadDeviceToken' || r.reason === 'Unregistered') {
        await del({ pk: d.pk, sk: d.sk }).catch(() => {});
      }
    }),
  );
}

// Payload builders ---------------------------------------------------------------------------

export const payloads = {
  nudge(p: {
    title: string;
    body: string;
    nudgeId: string;
    friendId: string;
    friendName: string;
    windowStart: string;
    windowEnd: string;
    minutes: number;
    avatarUrl?: string;
  }) {
    return {
      aps: {
        alert: { title: p.title, body: p.body },
        category: 'NUDGE',
        sound: 'default',
        'thread-id': 'nudge',
        'mutable-content': 1,
        'interruption-level': 'active',
      },
      type: 'nudge',
      nudgeId: p.nudgeId,
      friendId: p.friendId,
      friendName: p.friendName,
      windowStart: p.windowStart,
      windowEnd: p.windowEnd,
      minutes: p.minutes,
      ...(p.avatarUrl ? { avatarUrl: p.avatarUrl } : {}),
    };
  },
  background(type: 'availability.check' | 'nudge.cleanup' | 'calendar.sync', nudgeId?: string) {
    return { aps: { 'content-available': 1 }, type, ...(nudgeId ? { nudgeId } : {}) };
  },
  voip(p: { callId: string; nudgeId: string; callerId: string; callerName: string }) {
    return { type: 'call.incoming', ...p, hasVideo: true };
  },
  message(p: { friendId: string; title: string; body: string }) {
    return {
      aps: { alert: { title: p.title, body: p.body }, category: 'MESSAGE', 'thread-id': `msg-${p.friendId}`, sound: 'default' },
      type: 'message.new',
      friendId: p.friendId,
    };
  },
  alert(type: 'friend.request' | 'friend.accepted' | 'availability.stale', title: string, body: string, extra: Record<string, unknown> = {}) {
    return { aps: { alert: { title, body }, sound: 'default' }, type, ...extra };
  },
};
