import { twoBots } from "./scenarios/two-bots.js";
import { standIn } from "./scenarios/stand-in.js";

const [cmd, ...rest] = process.argv.slice(2);
const flag = (name: string) => rest.includes(`--${name}`);
const value = (name: string) => {
  const i = rest.indexOf(`--${name}`);
  return i >= 0 ? rest[i + 1] : undefined;
};

switch (cmd) {
  case "two-bots": {
    const ok = await twoBots({ verbose: flag("verbose"), trials: Number(value("trials") ?? 5) });
    process.exit(ok ? 0 : 1);
  }
  case "stand-in": {
    const friend = value("friend");
    if (!friend) throw new Error("--friend <handle> is required");
    await standIn({
      friend,
      skip: flag("skip"),
      shareAfterMs: value("share-after") ? Number(value("share-after")) : undefined,
      say: value("say"),
      speechWav: value("speech"),
    });
    break;
  }
  default:
    console.log(`usage:
  npm run bot -- two-bots [--verbose] [--trials 5]
  npm run bot -- stand-in --friend <your handle> [--skip] [--share-after 5000] [--say "remember that hike"] [--speech file.wav]`);
}
