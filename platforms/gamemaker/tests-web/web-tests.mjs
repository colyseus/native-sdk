#!/usr/bin/env node
// Headless driver for tests-web/harness.html — the GM wasm lane's smoke gate.
//
// Serves platforms/gamemaker/ statically, opens the harness in headless
// Chromium, and mirrors its console; exits 0 only when every scenario passed.
//
// Prerequisites:
//   - wasm-out/colyseus_wasm.js built (./build-wasm.sh)
//   - the prediction-tools playground server on :5173 (`pnpm dev --host 0.0.0.0`)
//   - puppeteer, resolved from the prediction-tools checkout's node_modules
//     (or set PUPPETEER_DIR to any directory that has it installed)

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const GM_ROOT = path.dirname(HERE); // platforms/gamemaker
const PORT = 8931;

function resolvePuppeteer() {
  const candidates = [
    process.env.PUPPETEER_DIR,
    path.resolve(GM_ROOT, "../../../demos/prediction-tools"),
  ].filter(Boolean);
  for (const dir of candidates) {
    try {
      const req = createRequire(path.join(dir, "package.json"));
      return req("puppeteer");
    } catch {
      /* next */
    }
  }
  console.error(
    "puppeteer not found — run `pnpm install` in demos/prediction-tools or set PUPPETEER_DIR"
  );
  process.exit(2);
}

const MIME = { ".html": "text/html", ".js": "text/javascript" };

const server = http.createServer((req, res) => {
  const url = req.url.split("?")[0];
  const file = path.join(GM_ROOT, url === "/" ? "tests-web/harness.html" : url);
  if (!file.startsWith(GM_ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404);
    return res.end("not found");
  }
  res.writeHead(200, { "Content-Type": MIME[path.extname(file)] ?? "application/octet-stream" });
  fs.createReadStream(file).pipe(res);
});

const bundle = path.join(GM_ROOT, "wasm-out/colyseus_wasm.js");
if (!fs.existsSync(bundle)) {
  console.error(`missing ${bundle} — run ./build-wasm.sh first`);
  process.exit(2);
}

const puppeteer = resolvePuppeteer();
server.listen(PORT, "127.0.0.1", async () => {
  const browser = await puppeteer.launch({ headless: "shell" });
  const page = await browser.newPage();

  let finished = null;
  const done = new Promise((resolve) => (finished = resolve));
  page.on("console", (msg) => {
    const text = msg.text();
    console.log("  [page]", text);
    const m = text.match(/^WEB TESTS FINISHED (\d+)\/(\d+)$/);
    if (m) finished({ pass: +m[1], total: +m[2] });
  });
  page.on("pageerror", (err) => console.error("  [pageerror]", err.message));

  await page.goto(`http://127.0.0.1:${PORT}/tests-web/harness.html`);
  const timeout = new Promise((resolve) =>
    setTimeout(() => resolve(null), 120_000)
  );
  const result = await Promise.race([done, timeout]);

  await browser.close();
  server.close();
  if (!result) {
    console.error("TIMEOUT: harness never finished");
    process.exit(1);
  }
  console.log(`\nweb tests: ${result.pass}/${result.total}`);
  process.exit(result.pass === result.total ? 0 : 1);
});
