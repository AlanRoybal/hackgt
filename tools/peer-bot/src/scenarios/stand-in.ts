// The bot plays "the friend" so one person with one phone can test nudges, calls and photo sync.
import { Bot, sleep } from "../bot.js";

export async function standIn(opts: {
  friend: string;
  skip?: boolean;
  shareAfterMs?: number;
  say?: string;
  speechWav?: string;
  verbose?: boolean;
}): Promise<void> {
  const bot = new Bot("friend-bot", undefined, { verbose: true, speechWav: opts.speechWav });
  await bot.start(`standin_${opts.friend}`.slice(0, 20), "Test Friend");
  const photos = await bot.seedPhotos(["Hike", "Cake"]);

  try {
    await bot.api.post("/friend-requests", { handle: opts.friend });
    console.log(`Sent a friend request to @${opts.friend}. Accept it in the app.`);
  } catch (e) {
    console.log(`Friend request: ${e}`);
  }

  bot.socket.on(async (e) => {
    if (e.type === "nudge.updated" && e.nudge && ["pending", "accepted_by_one"].includes(e.nudge.state) && !e.nudge.myResponse) {
      const action = opts.skip ? "skip" : "accept";
      console.log(`Nudge ${e.nudge.id}: ${action}`);
      if (!opts.skip) bot.socket.send({ action: "waiting", nudgeId: e.nudge.id });
      await bot.api.post(`/nudges/${e.nudge.id}/respond`, { action });
    }
    if (e.type === "call.matched") {
      await bot.joinCall(e.callId);
      if (opts.say) {
        await sleep(3000);
        bot.say(opts.say);
      }
      if (opts.shareAfterMs !== undefined) {
        await sleep(opts.shareAfterMs);
        bot.sharePhoto(photos[0]);
      }
    }
    if (e.type === "call.ended") console.log("Call ended.");
    if (e.type === "friend.accepted") console.log(`@${opts.friend} accepted. Tap "Call now" on the bot's profile, or wait for a nudge.`);
  });

  console.log("Standing in. Ctrl-C to stop.");
  await new Promise(() => {});
}
