// Tiny API client for integration tests against the deployed dev stage.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';

const here = path.dirname(fileURLToPath(import.meta.url));
const outputs = JSON.parse(readFileSync(path.join(here, '..', 'cdk-outputs.dev.json'), 'utf8'))['Nudge-dev'];
export const API = outputs.HttpApiUrl as string;
export const WS = outputs.WsUrl as string;
export const OUTPUTS = outputs;

export class ApiError extends Error {
  constructor(public status: number, public body: any) {
    super(`${status} ${JSON.stringify(body)}`);
  }
}

export async function call(method: string, p: string, token?: string, body?: unknown) {
  const r = await fetch(`${API}${p}`, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  const json = text ? JSON.parse(text) : undefined;
  if (!r.ok) throw new ApiError(r.status, json);
  return { status: r.status, body: json };
}

export interface TestUser {
  id: string;
  token: string;
  handle: string;
  req: (method: string, p: string, body?: unknown) => Promise<any>;
}

const rand = () => Math.random().toString(36).slice(2, 8);

/** Creates a fully onboarded dev user (ToS accepted, handle claimed, availability fresh, no quiet hours). */
export async function makeUser(label: string, opts: { onboard?: boolean } = {}): Promise<TestUser> {
  const username = `it_${label}_${rand()}`;
  const auth = (await call('POST', '/auth/dev', undefined, { username, displayName: label })).body;
  const token = auth.accessToken as string;
  const req = async (method: string, p: string, body?: unknown) => (await call(method, p, token, body)).body;
  const handle = username.slice(0, 20);
  if (opts.onboard !== false) {
    const me = await req('GET', '/me');
    await req('POST', '/me/tos', { version: me.currentTosVersion });
    await req('PUT', '/me/handle', { handle });
    await req('PATCH', '/me', { tz: 'UTC', settings: { quietStart: '00:00', quietEnd: '00:00', frequency: 'high' } });
    await req('PUT', '/me/availability', { busyBlocks: [], syncedAt: new Date().toISOString(), source: 'apple', tz: 'UTC' });
  }
  return { id: auth.userId, token, handle, req };
}

export async function befriend(a: TestUser, b: TestUser) {
  await a.req('POST', '/friend-requests', { handle: b.handle });
  await b.req('POST', `/friend-requests/${a.id}/accept`);
}

export async function cleanup(...users: (TestUser | undefined)[]) {
  for (const u of users) if (u) await u.req('DELETE', '/me').catch(() => {});
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function until<T>(fn: () => Promise<T | undefined | null | false>, timeoutMs = 20_000, everyMs = 500): Promise<T> {
  const end = Date.now() + timeoutMs;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error('timed out waiting');
    await sleep(everyMs);
  }
}

/** A WebSocket connection that records every server event. */
export async function openSocket(u: TestUser) {
  const ws = new WebSocket(`${WS}?token=${encodeURIComponent(u.token)}`);
  const events: any[] = [];
  ws.on('message', (d) => events.push(JSON.parse(String(d))));
  await new Promise<void>((resolve, reject) => {
    ws.once('open', () => resolve());
    ws.once('error', reject);
    ws.once('unexpected-response', (_req, res) => reject(new Error(`ws ${res.statusCode}`)));
  });
  return {
    ws,
    events,
    send: (m: unknown) => ws.send(JSON.stringify(m)),
    waitFor: (pred: (e: any) => boolean, timeoutMs = 20_000) => until(async () => events.find(pred), timeoutMs, 200),
    close: () => ws.close(),
  };
}
