import { describe, expect, it } from "vitest";
import {
  PhotoShareSession,
  displayRule,
  durationFor,
  enqueue,
  compareMessages,
  type ActivePhoto,
  type PhotoMessage,
  type DisplayState,
} from "../src/protocol.js";

// Deterministic fake clock + timers.
class Clock {
  t = 0;
  private timers: { at: number; fn: () => void; id: number }[] = [];
  private nextId = 0;
  setTimer = (ms: number, fn: () => void) => {
    const id = this.nextId++;
    this.timers.push({ at: this.t + ms, fn, id });
    return () => {
      this.timers = this.timers.filter((x) => x.id !== id);
    };
  };
  async advance(ms: number) {
    const end = this.t + ms;
    for (;;) {
      await flush();
      this.timers.sort((a, b) => a.at - b.at);
      const next = this.timers[0];
      if (!next || next.at > end) break;
      this.timers.shift();
      this.t = next.at;
      next.fn();
    }
    this.t = end;
    await flush();
  }
}
const flush = () => new Promise((r) => setTimeout(r, 0));

function pair(opts: { dropReady?: boolean } = {}) {
  const clock = new Clock();
  let shareN = 0;
  const displays: Record<string, DisplayState[]> = { A: [], B: [] };
  const sessions: Record<string, PhotoShareSession> = {};
  const mk = (id: "A" | "B", peer: "A" | "B") =>
    new PhotoShareSession({
      selfId: id,
      now: () => clock.t,
      setTimer: clock.setTimer,
      send: (m: PhotoMessage) => {
        if (opts.dropReady && m.type === "ready") return;
        queueMicrotask(() => sessions[peer].handle(m));
      },
      createShare: async (photoId) => `${id}-${photoId}-${shareN++}`,
      fetchShare: async () => {},
      onDisplayChange: (d) => displays[id].push(d),
    });
  sessions.A = mk("A", "B");
  sessions.B = mk("B", "A");
  return { clock, A: sessions.A, B: sessions.B, displays };
}

const photo = (shareId: string, senderId = "x"): ActivePhoto => ({ shareId, senderId, startedAt: 0, durationMs: 1 });

describe("displayRule truth table", () => {
  it("self when nobody shares", () => expect(displayRule(null, null)).toEqual({ kind: "self" }));
  it("mine when only I share", () => expect(displayRule(photo("m"), null).kind).toBe("mine"));
  it("other when only they share", () => expect(displayRule(null, photo("o")).kind).toBe("other"));
  it("other wins when both share", () => {
    const d = displayRule(photo("m"), photo("o"));
    expect(d.kind).toBe("other");
    expect(d.kind !== "self" && d.photo.shareId).toBe("o");
  });
});

describe("durations and queue", () => {
  it("shortens with queue length", () => {
    expect(durationFor(1)).toBe(6000);
    expect(durationFor(2)).toBe(4500);
    expect(durationFor(3)).toBe(3500);
    expect(durationFor(5)).toBe(3500);
  });
  it("drops the oldest beyond 5", () => {
    let q: number[] = [];
    for (let i = 1; i <= 7; i++) q = enqueue(q, i);
    expect(q).toEqual([3, 4, 5, 6, 7]);
  });
  it("orders by server timestamp then senderId", () => {
    const m = (senderId: string): PhotoMessage => ({ v: 1, type: "offer", seq: 1, shareId: "s", senderId });
    const list = [
      { timestampMs: 5, msg: m("b") },
      { timestampMs: 5, msg: m("a") },
      { timestampMs: 1, msg: m("z") },
    ].sort(compareMessages);
    expect(list.map((x) => x.msg.senderId)).toEqual(["z", "a", "b"]);
  });
});

describe("PhotoShareSession", () => {
  it("single share: both mini windows show the sender's photo, then revert together", async () => {
    const { clock, A, B } = pair();
    A.share("p1");
    await clock.advance(0);
    expect(A.display.kind).toBe("mine");
    expect(B.display.kind).toBe("other");
    await clock.advance(5999);
    expect(A.display.kind).toBe("mine");
    await clock.advance(1);
    expect(A.display.kind).toBe("self");
    expect(B.display.kind).toBe("self");
  });

  it("simultaneous share: each sees the other's photo", async () => {
    const { clock, A, B } = pair();
    A.share("a1");
    B.share("b1");
    await clock.advance(0);
    const a = A.display, b = B.display;
    expect(a.kind).toBe("other");
    expect(b.kind).toBe("other");
    expect(a.kind !== "self" && a.photo.senderId).toBe("B");
    expect(b.kind !== "self" && b.photo.senderId).toBe("A");
  });

  it("falls back cleanly when one of two simultaneous photos is cancelled", async () => {
    const { clock, A, B } = pair();
    A.share("a1");
    B.share("b1");
    await clock.advance(0);
    B.cancelMine();
    await clock.advance(0);
    expect(A.display.kind).toBe("mine"); // B's photo gone → A sees its own
    expect(B.display.kind).toBe("other"); // B still sees A's
  });

  it("queued photos show for less time while others wait behind them", async () => {
    const { clock, A, B } = pair();
    const shown: number[] = [];
    A.share("1"); A.share("2"); A.share("3");
    await clock.advance(0);
    let last = clock.t;
    let prev = B.display.kind !== "self" ? B.display.photo.shareId : "";
    for (let i = 0; i < 20000 && shown.length < 3; i += 250) {
      await clock.advance(250);
      const cur = B.display.kind !== "self" ? B.display.photo.shareId : "";
      if (cur !== prev) {
        if (prev) shown.push(clock.t - last);
        last = clock.t;
        prev = cur;
      }
    }
    // Duration is fixed at offer time from the sender's pending count: the first tap goes out
    // alone (6 s), the next leaves one behind it (4.5 s), the last goes alone (6 s).
    expect(shown).toEqual([6000, 4500, 6000]);
  });

  it("sender proceeds after 1.5 s when ready never arrives", async () => {
    const { clock, A, B } = pair({ dropReady: true });
    A.share("p");
    await clock.advance(1499);
    expect(A.display.kind).toBe("self");
    expect(B.display.kind).toBe("other");
    await clock.advance(1);
    expect(A.display.kind).toBe("mine");
  });

  it("ignores its own echoed messages", async () => {
    const { A } = pair();
    A.handle({ v: 1, type: "offer", seq: 1, shareId: "s", senderId: "A" });
    expect(A.display.kind).toBe("self");
  });
});
