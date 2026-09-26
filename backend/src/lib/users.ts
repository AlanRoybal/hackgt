// User records and their API projections (SPEC §3.1, §3.7).
import { DEFAULT_SETTINGS, type Availability, type Settings } from '../engine/types.js';
import { batchGet, get } from './db.js';
import { env } from './env.js';
import { notFound } from './http.js';
import { K } from './keys.js';
import { presignGet } from './s3.js';

export interface UserItem {
  pk: string;
  sk: string;
  id: string;
  handle?: string;
  displayName: string;
  avatarKey?: string;
  tz: string;
  settings: Settings;
  tosVersion?: string;
  tosAcceptedAt?: string;
  phoneHash?: string;
  phoneVerified?: boolean;
  frequencyBeforeLess?: Settings['frequency'];
  recentNudgeAts?: string[];
  lastNudgeAt?: string;
  lastStaleNoticeAt?: string;
  activeNudgeId?: string;
  activeCallId?: string;
  busyUntil?: string;
  username: string;
  createdAt: string;
  gsi1pk?: string;
  gsi1sk?: string;
}

export interface FriendshipItem {
  pk: string;
  sk: string;
  a: string;
  b: string;
  pairKey: string;
  nickname?: string;
  since: string;
  lastCallAt?: string;
  lastNudgeAt?: string;
}

export interface AvailabilityItem extends Availability {
  pk: string;
  sk: string;
  source?: string;
}

export const withDefaults = (s: Partial<Settings> | undefined): Settings => ({ ...DEFAULT_SETTINGS, ...(s ?? {}) });

export async function getUser(id: string): Promise<UserItem> {
  const u = await get<UserItem>(K.user(id));
  if (!u) throw notFound('user_not_found');
  u.settings = withDefaults(u.settings);
  return u;
}

export async function findUser(id: string): Promise<UserItem | undefined> {
  const u = await get<UserItem>(K.user(id));
  if (u) u.settings = withDefaults(u.settings);
  return u;
}

export async function loadUsers(ids: string[]): Promise<Map<string, UserItem>> {
  const items = await batchGet<UserItem>(ids.map(K.user));
  for (const u of items) u.settings = withDefaults(u.settings);
  return new Map(items.map((u) => [u.id, u]));
}

export async function loadAvailability(ids: string[]): Promise<Map<string, AvailabilityItem>> {
  const items = await batchGet<AvailabilityItem>(ids.map(K.avail));
  return new Map(items.map((a) => [a.pk.slice('USER#'.length), a]));
}

export async function avatarUrl(u: Pick<UserItem, 'avatarKey'>): Promise<string | undefined> {
  return u.avatarKey ? presignGet(u.avatarKey, 3600) : undefined;
}

export async function publicUser(u: UserItem) {
  return { id: u.id, handle: u.handle ?? '', displayName: u.displayName ?? '', avatarUrl: await avatarUrl(u) };
}

export type PublicUser = Awaited<ReturnType<typeof publicUser>>;

export async function userDTO(u: UserItem) {
  return {
    ...(await publicUser(u)),
    settings: withDefaults(u.settings),
    tz: u.tz,
    phoneVerified: !!u.phoneVerified,
    tosVersion: u.tosVersion,
    tosAcceptedAt: u.tosAcceptedAt,
  };
}

export async function meResponse(u: UserItem) {
  return {
    user: await userDTO(u),
    needsTos: u.tosVersion !== env.currentTosVersion,
    needsHandle: !u.handle,
    currentTosVersion: env.currentTosVersion,
  };
}

/** The name `viewer` sees for `friend`: their private nickname, else display name, else handle. */
export const nameFor = (friend: UserItem | undefined, friendship?: { nickname?: string }) =>
  friendship?.nickname || friend?.displayName || (friend?.handle ? `@${friend.handle}` : 'Your friend');

export const getFriendship = (a: string, b: string) => get<FriendshipItem>(K.friend(a, b));
