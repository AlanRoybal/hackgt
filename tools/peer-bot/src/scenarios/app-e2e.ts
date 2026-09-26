// Counterpart to ios/UITests/E2ETests: waits for the app user `e2e_<run>`, befriends them, messages,
// calls, joins the Chime meeting and shares a photo.
import { Bot, sleep } from "../bot.js";
import { stopServer } from "../browser.js";

export async function appE2E(run: string): Promise<boolean> {
  const bot = new Bot("e2e-bot", undefined, { verbose: true });
  try {
    await bot.start(`e2ebot_${run}`, "Test Bot");
    const [photo] = await bot.seedPhotos(["Garden"]);

    let target: any;
    for (let i = 0; i < 90 && !target; i++) {
      const { results } = await bot.api.get(`/users/search?q=${encodeURIComponent(`e2e_${run}`)}`);
      target = results.find((r: any) => r.handle === `e2e_${run}`);
      if (!target) await sleep(2000);
    }
    if (!target) throw new Error("app user never appeared");
    await bot.api.post("/friend-requests", { userId: target.id });
    await bot.socket.waitFor((e) => e.type === "friend.accepted", 120_000, "friend.accepted");
    await sleep(2000);
    await bot.api.post(`/friends/${target.id}/messages`, { body: "Hello from the bot" });

    await sleep(8000);
    const nudge = await bot.api.post(`/friends/${target.id}/call`);
    bot.socket.send({ action: "waiting", nudgeId: nudge.id });
    bot.mark("call.requested", { nudgeId: nudge.id });
    const matched = await bot.socket.waitFor((e) => e.type === "call.matched", 90_000, "call.matched");
    bot.mark("call.matched", { callId: matched.callId });
    await bot.joinCall(matched.callId);
    // Wait for the app to be in the meeting, then keep re-sharing so the UI test can't miss the 6 s window
    // while it's still dismissing permission alerts.
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline && !bot.log.some((l) => l.event === "chime.presence" && String(l.data?.detail).includes("true") && !String(l.data?.detail).includes(bot.log.find((x) => x.event === "call.joining")?.data?.attendeeId as string))) await sleep(500);
    let ended = false;
    void bot.socket.waitFor((e) => e.type === "call.ended", 180_000, "call.ended").then(() => (ended = true), () => {});
    for (let i = 0; i < 10 && !ended; i++) {
      await sleep(i === 0 ? 3000 : 12_000);
      if (!ended) bot.sharePhoto(photo);
    }
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
