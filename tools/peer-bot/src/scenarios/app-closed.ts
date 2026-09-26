// Counterpart to E2ETests.testNudgeArrivesWhileAppClosed: once the app user has accepted the bot and closed the
// app, runs the real matcher, takes the exact APNs payload the backend produced, delivers it to the simulator with
// `simctl push` (the app is not running), then waits for the user to accept from the notification and completes
// the match from the bot's side.
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { Bot, sleep } from "../bot.js";
import { stopServer } from "../browser.js";

export async function appClosed(run: string, udid: string, bundleId: string): Promise<boolean> {
  const bot = new Bot("closed-bot", undefined, { verbose: true });
  try {
    await bot.start(`e2ebot_${run}`, "Test Bot");
    let target: any;
    for (let i = 0; i < 90 && !target; i++) {
      const { results } = await bot.api.get(`/users/search?q=${encodeURIComponent(`e2e_${run}`)}`);
      target = results.find((r: any) => r.handle === `e2e_${run}`);
      if (!target) await sleep(2000);
    }
    if (!target) throw new Error("app user never appeared");
    await bot.api.post("/friend-requests", { userId: target.id });
    await bot.socket.waitFor((e) => e.type === "friend.accepted", 120_000, "friend.accepted");

    // The UI test terminates the app right after accepting; give it time.
    await sleep(12_000);

    // Real matcher, restricted to this pair. `now` is local noon so default quiet hours (00:00–08:00) can't
    // suppress it when the test runs at night; availability synced minutes ago is still fresh at that time.
    const noon = new Date();
    noon.setHours(12, 0, 0, 0);
    if (noon.getTime() < Date.now()) noon.setDate(noon.getDate() + 1);
    const match = await bot.api.post("/dev/matcher/run", { onlyUserIds: [target.id, bot.api.userId], immediate: true, now: noon.toISOString() });
    bot.mark("matcher", { created: match.created?.length, skipped: match.skipped });
    if (!match.created?.length) throw new Error(`matcher created no nudge: ${JSON.stringify(match.skipped)}`);

    const { pushes } = await bot.api.get(`/dev/pushes/${target.id}`);
    const push = pushes.find((p: any) => p.kind === "alert" && p.payload?.aps?.category === "NUDGE");
    if (!push) throw new Error("no NUDGE alert in the push log");
    const nudgeId = push.payload.nudgeId;
    bot.mark("push.payload", { nudgeId, title: push.payload.aps.alert.title, body: push.payload.aps.alert.body });

    // Deliver the backend's exact payload to the simulator while the app is closed.
    const file = `out/push-${run}.apns`;
    writeFileSync(file, JSON.stringify({ "Simulator Target Bundle": bundleId, ...push.payload }));
    execFileSync("xcrun", ["simctl", "push", udid, bundleId, file]);
    bot.mark("push.delivered");

    // The user taps Accept on the notification → the app launches and responds.
    const accepted = await bot.socket.waitFor(
      (e) => e.type === "nudge.updated" && e.nudge?.id === nudgeId && e.nudge?.theirResponse === "accepted",
      120_000,
      "user accepted from the notification",
    );
    bot.mark("user.accepted", { state: accepted.nudge.state });
    bot.socket.send({ action: "waiting", nudgeId });
    const r = await bot.api.post(`/nudges/${nudgeId}/respond`, { action: "accept" });
    await bot.joinCall(r.callId);
    await bot.socket.waitFor((e) => e.type === "call.ended", 180_000, "call.ended");
    bot.mark("done");
    return true;
  } catch (e) {
    console.error(String(e));
    return false;
  } finally {
    await bot.close();
    await stopServer();
  }
}
