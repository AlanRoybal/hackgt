// Counterpart to E2ETests.testAppUserCallsFromProfile: befriends the app user, then waits for them to tap
// "Call now" on the bot's profile. Lets it ring for a few seconds (so the UI test can see the waiting room),
// accepts, and joins the Chime meeting.
import { Bot, sleep } from "../bot.js";
import { stopServer } from "../browser.js";

export async function appCalls(run: string): Promise<boolean> {
  const bot = new Bot("callee-bot", undefined, { verbose: true });
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

    const ringing = await bot.socket.waitFor(
      (e) => e.type === "nudge.updated" && e.nudge?.kind === "direct" && e.nudge?.friend?.id === target.id && !e.nudge?.myResponse,
      180_000,
      "incoming Call now from the app user",
    );
    const nudgeId = ringing.nudge.id;
    bot.mark("ringing", { nudgeId, theirResponse: ringing.nudge.theirResponse });
    await sleep(8000);
    bot.socket.send({ action: "waiting", nudgeId });
    const r = await bot.api.post(`/nudges/${nudgeId}/respond`, { action: "accept" });
    bot.mark("accepted", { state: r.state, callId: r.callId });
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
