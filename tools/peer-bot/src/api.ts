// Minimal client for the Nudge HTTP + WebSocket APIs (SPEC §3.7, §3.8).
import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";

export interface BotConfig {
  httpUrl: string;
  wsUrl: string;
}

/** API/WS URLs from env, else from backend/cdk-outputs.<stage>.json (any key containing Http/WebSocket url). */
export function loadConfig(stage = process.env.NUDGE_STAGE ?? "dev"): BotConfig {
  if (process.env.NUDGE_API_URL && process.env.NUDGE_WS_URL) {
    return { httpUrl: strip(process.env.NUDGE_API_URL), wsUrl: process.env.NUDGE_WS_URL };
  }
  const here = dirname(fileURLToPath(import.meta.url));
  const file = resolve(here, `../../../backend/cdk-outputs.${stage}.json`);
  if (!existsSync(file)) throw new Error(`Set NUDGE_API_URL/NUDGE_WS_URL or deploy the backend (${file} missing)`);
  const outputs: Record<string, Record<string, string>> = JSON.parse(readFileSync(file, "utf8"));
  const flat: Record<string, string> = {};
  for (const stack of Object.values(outputs)) Object.assign(flat, stack);
  const find = (re: RegExp, valueRe: RegExp) =>
    Object.entries(flat).find(([k, v]) => re.test(k) && valueRe.test(v))?.[1];
  const httpUrl = find(/http|api/i, /^https:\/\//);
  const wsUrl = find(/ws|websocket|socket/i, /^wss:\/\//);
  if (!httpUrl || !wsUrl) throw new Error(`Could not find HTTP/WS URLs in ${file}`);
  return { httpUrl: strip(httpUrl), wsUrl };
}

const strip = (u: string) => u.replace(/\/+$/, "");

export interface AuthTokens {
  accessToken: string;
  idToken: string;
  refreshToken?: string;
  expiresIn: number;
  userId: string;
  isNew: boolean;
}

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string) {
    super(`${status} ${code}: ${message}`);
  }
}

export class Api {
  tokens?: AuthTokens;
  constructor(public readonly config: BotConfig) {}

  get userId(): string {
    if (!this.tokens) throw new Error("not signed in");
    return this.tokens.userId;
  }

  async devSignIn(username: string): Promise<AuthTokens> {
    this.tokens = await this.request<AuthTokens>("POST", "/auth/dev", { username }, false);
    return this.tokens;
  }

  async request<T = any>(method: string, path: string, body?: unknown, auth = true): Promise<T> {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (auth) headers.authorization = `Bearer ${this.tokens?.accessToken}`;
    const res = await fetch(this.config.httpUrl + path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    const json = text ? safeJson(text) : undefined;
    if (!res.ok) {
      const err = (json as any)?.error ?? {};
      throw new ApiError(res.status, err.code ?? "http_error", err.message ?? text);
    }
    return json as T;
  }

  get = <T = any>(p: string) => this.request<T>("GET", p);
  post = <T = any>(p: string, b?: unknown) => this.request<T>("POST", p, b ?? {});
  put = <T = any>(p: string, b?: unknown) => this.request<T>("PUT", p, b ?? {});
  patch = <T = any>(p: string, b?: unknown) => this.request<T>("PATCH", p, b ?? {});
  del = <T = any>(p: string) => this.request<T>("DELETE", p);

  /** Accept ToS, claim a handle, clear availability so nudges can match. Idempotent. */
  async onboard(handle: string, displayName: string): Promise<void> {
    const me = await this.get("/me");
    if (me.needsTos) await this.post("/me/tos", { version: me.currentTosVersion });
    if (me.needsHandle || me.user?.handle !== handle) {
      try {
        await this.put("/me/handle", { handle });
      } catch (e) {
        if (!(e instanceof ApiError && e.status === 409)) throw e;
      }
    }
    await this.patch("/me", { displayName, tz: "America/New_York", settings: { frequency: "high" } });
    await this.put("/me/availability", {
      busyBlocks: [],
      syncedAt: new Date().toISOString(),
      source: "apple",
      tz: "America/New_York",
    });
  }

  /** Make this user and `other` friends (requests from both sides; the second auto-accepts). */
  async befriend(other: Api): Promise<void> {
    await this.post("/friend-requests", { userId: other.userId });
    const r = await other.post("/friend-requests", { userId: this.userId });
    if (r?.relation !== "friends") await other.post(`/friend-requests/${this.userId}/accept`);
  }
}

function safeJson(t: string): unknown {
  try {
    return JSON.parse(t);
  } catch {
    return t;
  }
}

export type ServerEvent = { type: string; [k: string]: any };

/** WebSocket with typed waiting helpers. */
export class EventSocket {
  private ws?: WebSocket;
  private listeners = new Set<(e: ServerEvent) => void>();
  readonly events: { at: number; event: ServerEvent }[] = [];

  constructor(private readonly api: Api) {}

  async connect(): Promise<void> {
    const url = `${this.api.config.wsUrl}?token=${encodeURIComponent(this.api.tokens!.accessToken)}`;
    this.ws = new WebSocket(url);
    await new Promise<void>((res, rej) => {
      this.ws!.once("open", () => res());
      this.ws!.once("error", rej);
    });
    this.ws.on("message", (data) => {
      const event = safeJson(data.toString()) as ServerEvent;
      this.events.push({ at: Date.now(), event });
      for (const l of this.listeners) l(event);
    });
  }

  send(obj: Record<string, unknown>): void {
    this.ws?.send(JSON.stringify(obj));
  }

  on(fn: (e: ServerEvent) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  waitFor(pred: (e: ServerEvent) => boolean, timeoutMs = 15000, label = "event"): Promise<ServerEvent> {
    const seen = this.events.find((x) => pred(x.event));
    if (seen) return Promise.resolve(seen.event);
    return new Promise((res, rej) => {
      const t = setTimeout(() => {
        off();
        rej(new Error(`timed out waiting for ${label}`));
      }, timeoutMs);
      const off = this.on((e) => {
        if (pred(e)) {
          clearTimeout(t);
          off();
          res(e);
        }
      });
    });
  }

  close(): void {
    this.ws?.close();
  }
}
