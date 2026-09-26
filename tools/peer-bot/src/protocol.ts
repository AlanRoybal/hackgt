// Photo-share protocol (SPEC §2.5, §3.10), mirrored from the iOS PhotoShare module.
// Pure logic: the transport (Chime data messages), share API and clock are injected.

export type PhotoMessageType = "offer" | "ready" | "end" | "cancel";

export interface PhotoMessage {
  v: 1;
  type: PhotoMessageType;
  seq: number;
  shareId: string;
  senderId: string;
  durationMs?: number;
  queueIndex?: number;
  queueLength?: number;
}

export interface ActivePhoto {
  shareId: string;
  senderId: string;
  photoId?: string;
  startedAt: number;
  durationMs: number;
}

export type DisplayState =
  | { kind: "self" }
  | { kind: "mine"; photo: ActivePhoto }
  | { kind: "other"; photo: ActivePhoto };

export const MAX_QUEUE = 5;
export const READY_TIMEOUT_MS = 1500;

export function durationFor(queueLength: number): number {
  if (queueLength <= 1) return 6000;
  if (queueLength === 2) return 4500;
  return 3500;
}

/** The display rule: other participant's photo ?? my photo ?? self view. */
export function displayRule(mine: ActivePhoto | null, other: ActivePhoto | null): DisplayState {
  if (other) return { kind: "other", photo: other };
  if (mine) return { kind: "mine", photo: mine };
  return { kind: "self" };
}

/** Enqueue with the max-5 rule: the oldest pending item is dropped when full. */
export function enqueue<T>(queue: T[], item: T, max = MAX_QUEUE): T[] {
  const next = [...queue, item];
  while (next.length > max) next.shift();
  return next;
}

/** Orders incoming messages by Chime server timestamp, tiebreak on senderId. */
export function compareMessages(
  a: { timestampMs: number; msg: PhotoMessage },
  b: { timestampMs: number; msg: PhotoMessage },
): number {
  if (a.timestampMs !== b.timestampMs) return a.timestampMs - b.timestampMs;
  return a.msg.senderId < b.msg.senderId ? -1 : a.msg.senderId > b.msg.senderId ? 1 : 0;
}

export interface SessionDeps {
  selfId: string;
  now: () => number;
  setTimer: (ms: number, fn: () => void) => () => void; // returns cancel
  send: (msg: PhotoMessage) => void;
  createShare: (photoId: string) => Promise<string>; // POST /calls/{id}/shares → shareId
  fetchShare: (shareId: string) => Promise<void>; // GET share URL + download bytes
  onDisplayChange?: (state: DisplayState) => void;
  log?: (event: string, data?: Record<string, unknown>) => void;
}

interface Pending {
  photoId: string;
}

export class PhotoShareSession {
  private queue: Pending[] = [];
  private mine: ActivePhoto | null = null;
  private other: ActivePhoto | null = null;
  private offering: { shareId: string; photoId: string; durationMs: number; cancelTimer: () => void } | null = null;
  private mineTimer: (() => void) | null = null;
  private otherTimer: (() => void) | null = null;
  private creating = false; // a createShare call is in flight
  private seq = 0;
  private lastDisplay: DisplayState = { kind: "self" };

  constructor(private readonly deps: SessionDeps) {}

  get display(): DisplayState {
    return displayRule(this.mine, this.other);
  }

  get queueLength(): number {
    return this.queue.length + (this.offering ? 1 : 0) + (this.mine ? 1 : 0);
  }

  /** User tapped Show (or auto mode). */
  share(photoId: string): void {
    const inFlight = this.mine || this.offering || this.creating ? 1 : 0;
    this.queue = enqueue(this.queue, { photoId }, MAX_QUEUE - inFlight);
    this.deps.log?.("share.enqueued", { photoId, queued: this.queue.length });
    void this.pump();
  }

  /** Sender swiped their own photo away. */
  cancelMine(): void {
    if (!this.mine) return;
    const shareId = this.mine.shareId;
    this.deps.send(this.msg("cancel", shareId));
    this.finishMine();
  }

  handle(msg: PhotoMessage): void {
    if (msg.senderId === this.deps.selfId) return; // local echo
    switch (msg.type) {
      case "offer":
        void this.acceptOffer(msg);
        break;
      case "ready":
        if (this.offering && this.offering.shareId === msg.shareId) this.startMine();
        break;
      case "end":
      case "cancel":
        if (this.other && this.other.shareId === msg.shareId) this.clearOther();
        break;
    }
  }

  private async pump(): Promise<void> {
    if (this.mine || this.offering || this.creating || this.queue.length === 0) return;
    const queueLength = this.queue.length;
    const next = this.queue.shift()!;
    const durationMs = durationFor(queueLength);
    this.creating = true;
    let shareId: string;
    try {
      shareId = await this.deps.createShare(next.photoId);
    } catch (e) {
      this.deps.log?.("share.create_failed", { photoId: next.photoId, error: String(e) });
      this.creating = false;
      return void this.pump();
    }
    this.creating = false;
    const cancelTimer = this.deps.setTimer(READY_TIMEOUT_MS, () => {
      this.deps.log?.("offer.ready_timeout", { shareId });
      this.startMine();
    });
    this.offering = { shareId, photoId: next.photoId, durationMs, cancelTimer };
    this.deps.send({ ...this.msg("offer", shareId), durationMs, queueIndex: 0, queueLength });
    this.deps.log?.("offer.sent", { shareId, durationMs, queueLength });
  }

  private startMine(): void {
    const o = this.offering;
    if (!o) return;
    o.cancelTimer();
    this.offering = null;
    this.mine = { shareId: o.shareId, senderId: this.deps.selfId, photoId: o.photoId, startedAt: this.deps.now(), durationMs: o.durationMs };
    this.mineTimer = this.deps.setTimer(o.durationMs, () => {
      this.deps.send(this.msg("end", o.shareId));
      this.finishMine();
    });
    this.emit();
  }

  private finishMine(): void {
    this.mineTimer?.();
    this.mineTimer = null;
    this.mine = null;
    this.emit();
    void this.pump();
  }

  private async acceptOffer(msg: PhotoMessage): Promise<void> {
    try {
      await this.deps.fetchShare(msg.shareId);
    } catch (e) {
      this.deps.log?.("offer.fetch_failed", { shareId: msg.shareId, error: String(e) });
      return;
    }
    this.deps.send(this.msg("ready", msg.shareId));
    this.otherTimer?.();
    const durationMs = msg.durationMs ?? durationFor(msg.queueLength ?? 1);
    this.other = { shareId: msg.shareId, senderId: msg.senderId, startedAt: this.deps.now(), durationMs };
    this.otherTimer = this.deps.setTimer(durationMs, () => this.clearOther());
    this.emit();
  }

  private clearOther(): void {
    this.otherTimer?.();
    this.otherTimer = null;
    this.other = null;
    this.emit();
  }

  private msg(type: PhotoMessageType, shareId: string): PhotoMessage {
    return { v: 1, type, seq: ++this.seq, shareId, senderId: this.deps.selfId };
  }

  private emit(): void {
    const d = this.display;
    const key = (s: DisplayState) => (s.kind === "self" ? "self" : `${s.kind}:${s.photo.shareId}`);
    if (key(d) !== key(this.lastDisplay)) {
      this.lastDisplay = d;
      this.deps.log?.("display", { kind: d.kind, shareId: d.kind === "self" ? null : d.photo.shareId });
      this.deps.onDisplayChange?.(d);
    }
  }
}
