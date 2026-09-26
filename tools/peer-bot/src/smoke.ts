import { openBotPage, stopServer } from "./browser.js";
const p = await openBotPage({ name: "smoke", onData: () => {} });
const b64: string = await p.page.evaluate(() => (window as any).nudgeBot.makePhoto("Smoke", 200));
const devices = await p.page.evaluate(async () => (await navigator.mediaDevices.enumerateDevices()).map((d) => d.kind));
console.log("jpeg bytes", Buffer.from(b64, "base64").length, "devices", devices.join(","));
await p.close();
await stopServer();
