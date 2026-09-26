// A scripted Nudge user: HTTP + WS client, headless Chime participant, photo-share protocol.
import { createHash } from "node:crypto";
import { Api, EventSocket, loadConfig, type BotConfig } from "./api.js";
import { openBotPage, type BotPage } from "./browser.js";
import { PhotoShareSession, type DisplayState, type PhotoMessage } from "./protocol.js";

export interface Timing {
  bot: string;
  event: string;
  at: number;
  data?: Record<string, unknown>;
}

export class Bot {
  readonly api: Api;
  readonly socket: EventSocket;
  page?: BotPage;
  session?: PhotoShareSession;
  callId?: string;
  displayHistory: { at: number; state: DisplayState }[] = [];
  readonly log: Timing[] = [];

  constructor(readonly name: string, config: BotConfig = loadConfig(), private readonly opts: { speechWav?: string; verbose?: boolean } = {}) {
    this.api = new Api(config);
    this.socket = new EventSocket(this.api);
  }

  mark(event: string, data?: Record<string, unknown>): void {
    const t = { bot: this.name, event, at: Date.now(), data };
    this.log.push(t);
    if (this.opts.verbose) console.log(`${new Date(t.at).toISOString().slice(11, 23)} [${this.name}] ${event}`, data ? JSON.stringify(data) : "");
  }

  async start(handle: string, displayName = handle): Promise<void> {
    await this.api.devSignIn(`bot_${handle}`);
    await this.api.onboard(handle, displayName);
    await this.socket.connect();
    this.mark("ready", { userId: this.api.userId });
  }

  /** Uploads `count` generated photos through the real index pipeline and waits until indexed. Returns asset hashes. */
  async seedPhotos(labels: string[], timeoutMs = 120_000): Promise<string[]> {
    const page = await this.ensurePage();
    const items = labels.map((label, i) => {
      const b64 = page.page.evaluate((l: string, h: number) => (window as any).nudgeBot.makePhoto(l, h), label, (i * 67) % 360);
      return { label, b64 };
    });
    const bytes = await Promise.all(items.map(async (x) => Buffer.from(await x.b64, "base64")));
    const meta = bytes.map((b) => ({
      assetHash: createHash("sha256").update(b).digest("hex").slice(0, 32),
      takenAt: new Date(Date.now() - 86_400_000).toISOString(),
      place: "Atlanta, GA",
      isScreenshot: false,
      width: 1024,
      height: 768,
    }));
    const res = await this.api.post("/photos/uploads", { items: meta });
    for (const u of res.uploads ?? []) {
      const i = meta.findIndex((m) => m.assetHash === u.assetHash);
      const put = await fetch(u.uploadUrl, { method: "PUT", headers: { "content-type": "image/jpeg" }, body: bytes[i] });
      if (!put.ok) throw new Error(`upload failed ${put.status}`);
    }
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const s = await this.api.get("/photos/status");
      if (s.indexed + s.excluded + s.failed >= meta.length && s.pending === 0) break;
      if (Date.now() > deadline) throw new Error(`photos not indexed in time: ${JSON.stringify(s)}`);
      await sleep(2000);
    }
    this.mark("photos.seeded", { count: meta.length });
    return meta.map((m) => m.assetHash);
  }

  async joinCall(callId: string): Promise<void> {
    this.callId = callId;
    const join = await this.api.get(`/calls/${callId}/join`);
    const page = await this.ensurePage();
    this.session = new PhotoShareSession({
      selfId: this.api.userId,
      now: Date.now,
      setTimer: (ms, fn) => {
        const t = setTimeout(fn, ms);
        return () => clearTimeout(t);
      },
      send: (msg: PhotoMessage) => {
        this.mark(`photo.send.${msg.type}`, { shareId: msg.shareId });
        void page.page.evaluate((j: string) => (window as any).nudgeBot.send(j), JSON.stringify(msg));
      },
      createShare: async (photoId) => (await this.api.post(`/calls/${callId}/shares`, { photoId })).shareId,
      fetchShare: async (shareId) => {
        const { url } = await this.api.get(`/calls/${callId}/shares/${shareId}`);
        const r = await fetch(url);
        if (!r.ok) throw new Error(`share download ${r.status}`);
        await r.arrayBuffer();
      },
      onDisplayChange: (state) => {
        this.displayHistory.push({ at: Date.now(), state });
        this.mark("display", { kind: state.kind, shareId: state.kind === "self" ? null : state.photo.shareId });
      },
    });
    await page.page.evaluate((m: unknown, a: unknown) => (window as any).nudgeBot.join(m, a), join.meeting, join.attendee);
    this.mark("call.joined", { callId });
  }

  sharePhoto(photoId: string): void {
    this.mark("photo.tap_show", { photoId });
    this.session?.share(photoId);
  }

  /** Sends a final transcript segment as if this bot had spoken it. */
  say(text: string): void {
    const now = Date.now();
    this.mark("transcript.sent", { text });
    this.socket.send({ action: "transcript", callId: this.callId, segId: crypto.randomUUID(), text, startMs: 0, endMs: 1500, clientTs: now });
  }

  async endCall(): Promise<void> {
    if (!this.callId) return;
    await this.api.post(`/calls/${this.callId}/end`);
    await this.page?.page.evaluate(() => (window as any).nudgeBot.leave());
    this.mark("call.ended");
  }

  async close(): Promise<void> {
    this.socket.close();
    await this.page?.close();
  }

  private async ensurePage(): Promise<BotPage> {
    this.page ??= await openBotPage({
      name: this.name,
      speechWav: this.opts.speechWav,
      onData: (json, timestampMs) => {
        const msg = JSON.parse(json) as PhotoMessage;
        if (msg.senderId !== this.api.userId) this.mark(`photo.recv.${msg.type}`, { shareId: msg.shareId, timestampMs });
        this.session?.handle(msg);
      },
      onEvent: (name, detail) => this.mark(`chime.${name}`, detail ? { detail } : undefined),
    });
    return this.page;
  }
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
