import { randomBytes, randomUUID } from 'node:crypto';
import { GetParametersCommand, SSMClient } from '@aws-sdk/client-ssm';
import { deriveWhoopSignal } from '../engine/whoop.js';
import { del, get, put, update, queryGsi, isConditionalFailure } from './db.js';
import { env } from './env.js';
import { HttpError, bad } from './http.js';
import { getUser } from './users.js';

export const whoopKey = (id: string) => ({ pk: `USER#${id}`, sk: 'WHOOP' });
const stateKey = (id: string) => ({ pk: `USER#${id}`, sk: 'WHOOP_STATE' });
const REDIRECT = 'app.nudge.whoop://oauth';
const ROOT = 'https://api.prod.whoop.com';

async function config() {
  const base = `/nudge/${env.stage}/whoop/`;
  const r = await new SSMClient({}).send(new GetParametersCommand({ Names: ['clientId', 'clientSecret'].map(n => base + n), WithDecryption: true }));
  const values = Object.fromEntries((r.Parameters ?? []).map(p => [p.Name!.slice(base.length), p.Value!]));
  if (!values.clientId || !values.clientSecret) throw new HttpError(503, 'whoop_not_configured');
  return values;
}

async function tokens(body: Record<string, string>) {
  const cfg = await config();
  const response = await fetch(`${ROOT}/oauth/oauth2/token`, { method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ ...body, client_id: cfg.clientId, client_secret: cfg.clientSecret }), signal: AbortSignal.timeout(8000) });
  if (!response.ok) throw new HttpError(502, 'whoop_authorization_failed');
  const result = await response.json() as any;
  if (typeof result.access_token !== 'string' || typeof result.refresh_token !== 'string' || !(result.expires_in > 0)) throw new HttpError(502, 'whoop_invalid_token');
  return { accessToken: result.access_token, refreshToken: result.refresh_token, expiresAt: Date.now() + result.expires_in * 1000 };
}

export async function whoopStatus(id: string) {
  const row = await get(whoopKey(id));
  return { connected: !!row, sleepEnabled: row?.sleepEnabled ?? true, workoutEnabled: row?.workoutEnabled ?? true,
    syncedAt: row?.signal?.syncedAt, sleepStart: row?.signal?.sleepStart, sleepEnd: row?.signal?.sleepEnd,
    workoutUntil: row?.signal?.workoutUntil, syncFailed: row?.syncFailed ?? false };
}

export async function startWhoop(id: string) {
  if (await get(whoopKey(id))) throw bad('whoop_already_connected');
  const cfg = await config();
  const state = randomBytes(6).toString('base64url'); // WHOOP documents eight-character state.
  await put({ ...stateKey(id), oauthState: state, ttl: Math.floor(Date.now() / 1000) + 600 });
  const url = new URL(`${ROOT}/oauth/oauth2/auth`);
  url.search = new URLSearchParams({ client_id: cfg.clientId, redirect_uri: REDIRECT,
    response_type: 'code', scope: 'offline read:sleep read:workout', state }).toString();
  return { url: url.toString() };
}

export async function finishWhoop(id: string, code: unknown, state: unknown) {
  if (typeof code !== 'string' || code.length > 2048 || typeof state !== 'string') throw bad('invalid_oauth_response');
  const saved = await get(stateKey(id));
  if (!saved || saved.oauthState !== state || saved.ttl < Date.now() / 1000) throw bad('invalid_oauth_state');
  // Conditional consumption prevents replay of the same authorization response.
  try { await del(stateKey(id), 'oauthState = :state', { ':state': state }); }
  catch (e) { if (isConditionalFailure(e)) throw bad('invalid_oauth_state'); throw e; }
  await getUser(id);
  const credentials = await tokens({ grant_type: 'authorization_code', code, redirect_uri: REDIRECT });
  await put({ ...whoopKey(id), ...credentials, generation: randomUUID(), userId: id,
    sleepEnabled: true, workoutEnabled: true, gsi1pk: 'WHOOP', gsi1sk: id });
  await syncWhoop(id);
  return whoopStatus(id);
}

async function records(kind: 'sleep' | 'workout', access: string) {
  const rows: any[] = [];
  let next: string | undefined;
  for (let page = 0; page < 10; page++) {
    const url = new URL(`${ROOT}/developer/v2/activity/${kind}`);
    url.searchParams.set('start', new Date(Date.now() - 7 * 86_400_000).toISOString());
    url.searchParams.set('limit', '25');
    if (next) url.searchParams.set('nextToken', next);
    const r = await fetch(url, { headers: { Authorization: `Bearer ${access}` }, signal: AbortSignal.timeout(8000) });
    if (!r.ok) throw new HttpError(502, 'whoop_sync_failed');
    const value = await r.json() as any;
    if (!Array.isArray(value.records)) throw new HttpError(502, 'whoop_invalid_records');
    rows.push(...value.records);
    next = value.next_token;
    if (!next) return rows;
  }
  throw new HttpError(502, 'whoop_too_many_records');
}

export async function syncWhoop(id: string) {
  const key = whoopKey(id);
  let row = await get(key);
  if (!row) return;
  const generation = row.generation;
  try {
    row = await update(key, { syncUntil: Date.now() + 120_000 }, {
      condition: 'generation = :generation AND (attribute_not_exists(syncUntil) OR syncUntil < :now)',
      values: { ':generation': generation, ':now': Date.now() } });
  } catch (e) { if (isConditionalFailure(e)) return; throw e; }
  const opts = { condition: 'generation = :generation', values: { ':generation': generation } };
  try {
    if (row.expiresAt < Date.now() + 60_000) {
      const credentials = await tokens({ grant_type: 'refresh_token', refresh_token: row.refreshToken, scope: 'offline' });
      await update(key, credentials, opts);
      Object.assign(row, credentials);
    }
    const [sleeps, workouts, user] = await Promise.all([records('sleep', row.accessToken), records('workout', row.accessToken), getUser(id)]);
    const signal = deriveWhoopSignal(sleeps, workouts, user.tz, Date.now());
    await update(key, { signal, syncFailed: false }, opts);
  } catch (e) {
    if (!isConditionalFailure(e)) {
      await update(key, { syncFailed: true, signal: undefined }, opts).catch(() => {});
      console.warn('WHOOP sync failed', { name: (e as Error).name });
    }
  } finally {
    await update(key, { syncUntil: undefined }, opts).catch(() => {});
  }
}

export async function setWhoopOptions(id: string, body: any) {
  if (typeof body.sleepEnabled !== 'boolean' || typeof body.workoutEnabled !== 'boolean') throw bad('invalid_whoop_options');
  await update(whoopKey(id), { sleepEnabled: body.sleepEnabled, workoutEnabled: body.workoutEnabled }, { condition: 'attribute_exists(pk)' });
  return whoopStatus(id);
}

export async function disconnectWhoop(id: string) {
  const row = await get(whoopKey(id));
  if (row) {
    // Delete locally first so in-flight sync cannot restore a disconnected integration.
    await del(whoopKey(id));
    try {
      const credentials = row.expiresAt < Date.now() ? await tokens({ grant_type: 'refresh_token', refresh_token: row.refreshToken, scope: 'offline' }) : row;
      const response = await fetch(`${ROOT}/developer/v2/user/access`, { method: 'DELETE', headers: { Authorization: `Bearer ${credentials.accessToken}` }, signal: AbortSignal.timeout(8000) });
      if (!response.ok && response.status !== 401) console.warn('WHOOP revocation not confirmed', { status: response.status });
    } catch { console.warn('WHOOP revoke unavailable; connection removed locally'); }
  }
  await del(stateKey(id));
}

export async function syncWhoopConnections() {
  for (const row of await queryGsi('WHOOP')) {
    try { await syncWhoop(row.userId); }
    catch (e) { console.warn('WHOOP connection sync skipped', { name: (e as Error).name }); }
  }
}
