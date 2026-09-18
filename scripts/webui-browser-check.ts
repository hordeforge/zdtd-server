// Real-browser check of the Preact dashboard (ADR 0040). Manual, not part of
// `make lint`: it needs a browser and playwright, which CI does not carry.
//
// What it proves that the unit tests cannot: the committed page boots in a real
// engine, signs in through the shipped login form, renders every panel from
// GET /api/state.json, paints the tick chart on the canvas, and answers pointer
// scrub. Canvas painting and scrub are the two behaviours the Zig tests and the
// happy-dom checks cannot reach.
//
// Usage:
//   # stage playwright once (the repo tracks no node_modules)
//   mkdir -p ~/.cache/zdtd/webui-e2e && cd ~/.cache/zdtd/webui-e2e
//   printf '{"type":"module"}\n' > package.json && bun add playwright
//   # boot the server, then run
//   ZDTD_WEBUI_SECRET=<secret> bun run <repo>/scripts/webui-browser-check.ts \
//       http://127.0.0.1:<webui-port>
//
// Exit status 0 only when the panels render, the canvas has content, scrub
// changes the live readout, no page error was raised and no request failed.
import { chromium } from "playwright";

const secret = process.env.ZDTD_WEBUI_SECRET;
if (!secret) throw new Error("set ZDTD_WEBUI_SECRET to the server's webui secret");
const base = process.argv[2] ?? "http://127.0.0.1:27023";
const chrome = process.env.CHROME ?? "/usr/bin/chromium";

const browser = await chromium.launch({
  executablePath: chrome,
  args: ["--no-sandbox", "--disable-dev-shm-usage"],
});
const context = await browser.newContext({ viewport: { width: 1360, height: 950 } });
const page = await context.newPage();
const errors: string[] = [];
const badResponses: string[] = [];
page.on("pageerror", (e) => errors.push(`pageerror: ${String(e)}`));
page.on("console", (m) => {
  if (m.type() === "error") errors.push(`console: ${m.text()}`);
});
page.on("response", (r) => {
  if (r.status() >= 400) badResponses.push(`${r.status()} ${r.url()}`);
});

// Sign in for real: the dashboard cookie is the session token the server issues
// on the login POST, so this exercises the shipped auth path.
await page.goto(`${base}/login`, { waitUntil: "domcontentloaded" });
await page.fill("#login-token", secret);
await Promise.all([
  page.waitForURL(`${base}/`),
  page.click('form[action="/login"] button[type=submit]'),
]);
await page.waitForSelector("#app table, #app [role=tabpanel]", { timeout: 20000 });

// Let several polls land so the chart has samples to paint.
await page.waitForTimeout(9000);

const nodes = await page.evaluate(() => document.querySelectorAll("#app *").length);
const painted = await page.evaluate(() => {
  const c = document.querySelector("#apm-canvas") as HTMLCanvasElement | null;
  if (!c) return { found: false, width: 0, height: 0, opaquePixels: 0 };
  const g = c.getContext("2d");
  if (!g) return { found: true, width: c.width, height: c.height, opaquePixels: -1 };
  const d = g.getImageData(0, 0, c.width, c.height).data;
  let opaque = 0;
  for (let i = 3; i < d.length; i += 4) if (d[i] !== 0) opaque++;
  return { found: true, width: c.width, height: c.height, opaquePixels: opaque };
});

const before = (await page.textContent("#apm-chart-live"))?.trim() ?? "";
const box = await page.locator("#apm-canvas").boundingBox();
let scrubMoved = false;
if (box) {
  await page.mouse.move(box.x + box.width * 0.25, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width * 0.85, box.y + box.height / 2, { steps: 10 });
  await page.mouse.up();
  await page.waitForTimeout(300);
  const after = (await page.textContent("#apm-chart-live"))?.trim() ?? "";
  scrubMoved = after !== before && after.length > 0;
}

const tabIds = await page
  .locator("[role=tab]")
  .evaluateAll((els) => els.map((e) => (e as HTMLElement).id));

const result = {
  nodes,
  painted,
  tabs: tabIds,
  scrubMoved,
  liveBefore: before,
  badResponses,
  errors,
};
console.log(JSON.stringify(result, null, 2));
await browser.close();

const ok =
  painted.found &&
  painted.opaquePixels > 1000 &&
  tabIds.length >= 4 &&
  scrubMoved &&
  badResponses.length === 0 &&
  errors.length === 0;
console.log(ok ? "BROWSER-CHECK-OK" : "BROWSER-CHECK-FAILED");
process.exit(ok ? 0 : 1);
