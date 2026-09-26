// Two bots in one call: exercises nudge → call match, Chime join, and the photo-share protocol end to end.
import { mkdirSync, writeFileSync } from "node:fs";
import { Bot, sleep } from "../bot.js";
import { stopServer } from "../browser.js";

interface Check {
  name: string;
  pass: boolean;
  detail?: string;
}

const pct = (xs: number[], p: number) => {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)];
};

/** Time from a tap to the given bot's display showing that shareId. */
function showLatency(sender: Bot, viewer: Bot, since: number): number | undefined {
  const shown = viewer.displayHistory.find((d) => d.at >= since && d.state.kind !== "self");
  return shown ? shown.at - since : undefined;
}

export async function twoBots(opts: { verbose?: boolean; trials?: number }): Promise<boolean> {
  const run = Date.now().toString(36);
  const A = new Bot("A", undefined, { verbose: opts.verbose });
  const B = new Bot("B", undefined, { verbose: opts.verbose });
  const checks: Check[] = [];
  const check = (name: string, pass: boolean, detail?: string) => {
    checks.push({ name, pass, detail });
    console.log(`${pass ? "PASS" : "FAIL"}  ${name}${detail ? `  (${detail})` : ""}`);
  };

  try {
    await Promise.all([A.start(`pba_${run}`, "Bot A"), B.start(`pbb_${run}`, "Bot B")]);
    await A.api.befriend(B.api);
    const [photosA, photosB] = await Promise.all([
      A.seedPhotos(["A one", "A two", "A three", "A four"]),
      B.seedPhotos(["B one", "B two"]),
    ]);
    check("photos indexed through the real pipeline", photosA.length === 4 && photosB.length === 2);

    // Direct call: A is pre-accepted and waits; B accepts from its waiting room.
    const nudge = await A.api.post(`/friends/${B.api.userId}/call`);
    A.socket.send({ action: "waiting", nudgeId: nudge.id });
    await B.socket.waitFor((e) => e.type === "nudge.updated" && e.nudge?.id === nudge.id, 15000, "B nudge.updated");
    B.socket.send({ action: "waiting", nudgeId: nudge.id });
    const responded = await B.api.post(`/nudges/${nudge.id}/respond`, { action: "accept" });
    // The responder completes the match, so its respond response carries the callId; A waits in the room.
    const mA = await A.socket.waitFor((e) => e.type === "call.matched", 15000, "A call.matched");
    check("waiting participant gets call.matched; responder gets the same callId", mA.callId === responded.callId, mA.callId);

    await Promise.all([A.joinCall(mA.callId), B.joinCall(responded.callId)]);
    check("both joined the Chime meeting", true);
    await sleep(1500);

    // 1. Single share, repeated for latency.
    const lat: number[] = [];
    let singleOk = true;
    for (let i = 0; i < (opts.trials ?? 5); i++) {
      const t = Date.now();
      A.sharePhoto(photosA[i % photosA.length]);
      await sleep(1200);
      const la = showLatency(A, A, t), lb = showLatency(A, B, t);
      const a = A.session!.display, b = B.session!.display;
      singleOk &&= a.kind === "mine" && b.kind === "other" && a.photo.shareId === b.photo.shareId;
      if (la !== undefined && lb !== undefined) lat.push(Math.max(la, lb));
      await sleep(6500); // let it expire
      singleOk &&= A.session!.display.kind === "self" && B.session!.display.kind === "self";
    }
    check("single share: both mini windows show the sender's photo, then both revert", singleOk);
    check(
      "Show → visible on both p95 ≤ 800 ms",
      lat.length > 0 && pct(lat, 95) <= 800,
      `n=${lat.length} p50=${pct(lat, 50)}ms p95=${pct(lat, 95)}ms`,
    );

    // 2. Simultaneous share.
    A.sharePhoto(photosA[0]);
    B.sharePhoto(photosB[0]);
    await sleep(1500);
    const a = A.session!.display, b = B.session!.display;
    check(
      "simultaneous share: each sees the other's photo",
      a.kind === "other" && b.kind === "other" && a.photo.senderId === B.api.userId && b.photo.senderId === A.api.userId,
      `A=${a.kind} B=${b.kind}`,
    );
    B.session!.cancelMine();
    await sleep(800);
    check("after B cancels, A falls back to its own photo", A.session!.display.kind === "mine", A.session!.display.kind);
    await sleep(6500);

    // 3. Queue: three taps in a row.
    const qStart = Date.now();
    for (const p of photosA.slice(0, 3)) A.sharePhoto(p);
    await sleep(18_500);
    const seg = B.displayHistory.filter((d) => d.at >= qStart);
    const durations: number[] = [];
    for (let i = 0; i < seg.length - 1; i++) if (seg[i].state.kind !== "self") durations.push(seg[i + 1].at - seg[i].at);
    const expected = [6000, 4500, 6000];
    const close = durations.length === 3 && durations.every((d, i) => Math.abs(d - expected[i]) <= 400);
    check("queue of 3: shown for 6 s, 4.5 s, 6 s on the viewer", close, durations.join(", ") + " ms");

    // 4. End call → summary.
    await A.endCall();
    await B.page?.page.evaluate(() => (window as any).nudgeBot.leave());
    const ended = await B.socket.waitFor((e) => e.type === "call.ended", 15000, "B call.ended").then(() => true, () => false);
    check("ending on one side ends it for the other (call.ended)", ended);

    return checks.every((c) => c.pass);
  } catch (e) {
    check("scenario ran to completion", false, String(e));
    return false;
  } finally {
    mkdirSync("out", { recursive: true });
    const file = `out/two-bots-${run}.json`;
    writeFileSync(file, JSON.stringify({ checks, log: [...A.log, ...B.log].sort((x, y) => x.at - y.at) }, null, 2));
    console.log(`report: tools/peer-bot/${file}`);
    await Promise.allSettled([A.close(), B.close()]);
    await stopServer();
  }
}
