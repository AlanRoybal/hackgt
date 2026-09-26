// Launches headless Chrome with fake camera/mic and loads the bundled Chime page.
import { build } from "esbuild";
import { createServer, type Server } from "node:http";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import puppeteer, { type Browser, type Page } from "puppeteer";

const here = dirname(fileURLToPath(import.meta.url));

let bundle: Promise<string> | undefined;
function pageBundle(): Promise<string> {
  bundle ??= build({
    entryPoints: [resolve(here, "../page/chime-page.ts")],
    bundle: true,
    write: false,
    format: "iife",
    platform: "browser",
    target: "es2020",
    logLevel: "silent",
    // The SDK drags in AWS credential providers for its messaging client; they never run in the page,
    // so Node built-ins resolve to an empty module.
    plugins: [
      {
        name: "empty-node-builtins",
        setup(b) {
          b.onResolve({ filter: /^(node:.*|fs|os|path|crypto|child_process|http|https|stream|url|util|net|tls|zlib|process|buffer)$/ }, (a) => ({
            path: a.path,
            namespace: "empty",
          }));
          b.onLoad({ filter: /.*/, namespace: "empty" }, () => ({ contents: "module.exports = {};", loader: "js" }));
        },
      },
    ],
  }).then((r) => r.outputFiles[0].text);
  return bundle;
}

let server: Promise<{ server: Server; url: string }> | undefined;
function serve(): Promise<{ server: Server; url: string }> {
  server ??= pageBundle().then(
    (js) =>
      new Promise((res) => {
        const html = `<!doctype html><meta charset="utf-8"><title>peer-bot</title><script>${js}</script>`;
        const s = createServer((_req, reply) => {
          reply.writeHead(200, { "content-type": "text/html" });
          reply.end(html);
        }).listen(0, "127.0.0.1", () => {
          const addr = s.address();
          res({ server: s, url: `http://localhost:${typeof addr === "object" && addr ? addr.port : 0}/` });
        });
      }),
  );
  return server;
}

export interface BotPage {
  browser: Browser;
  page: Page;
  close(): Promise<void>;
}

export async function openBotPage(opts: {
  name: string;
  speechWav?: string;
  onData: (json: string, timestampMs: number, senderAttendeeId: string) => void;
  onEvent?: (name: string, detail: string) => void;
}): Promise<BotPage> {
  const { url } = await serve();
  const args = [
    "--use-fake-device-for-media-stream",
    "--use-fake-ui-for-media-stream",
    "--autoplay-policy=no-user-gesture-required",
  ];
  if (opts.speechWav) args.push(`--use-file-for-fake-audio-capture=${resolve(opts.speechWav)}`);
  const browser = await puppeteer.launch({ headless: true, args });
  const page = await browser.newPage();
  page.on("pageerror", (e) => console.error(`[${opts.name} page] ${e}`));
  page.on("console", (m) => {
    if (m.type() === "error") console.error(`[${opts.name} page] ${m.text()}`);
  });
  await page.exposeFunction("__onData", opts.onData);
  await page.exposeFunction("__onEvent", (n: string, d: string) => opts.onEvent?.(n, d));
  await page.goto(url);
  await page.waitForFunction(() => !!(window as any).nudgeBot);
  return { browser, page, close: () => browser.close() };
}

export async function stopServer(): Promise<void> {
  if (server) (await server).server.close();
}
