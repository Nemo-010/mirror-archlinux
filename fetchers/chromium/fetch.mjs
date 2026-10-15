#!/usr/bin/env node
//
// Retrieve a URL with the full Chrome-for-Testing build of Chromium.
//
//   node fetch.mjs URL OUT [REFERER]
//
// The request is an in-page fetch(), so it uses Chromium's own network stack,
// its client hints and its cookie jar. Playwright's APIRequestContext is a
// separate Node-side client and does not produce the same request, which
// matters when an origin tells the two apart.
//
// Environment:
//   CHROME_UA    user agent (default: derived from the running build)
//   CHROME_WAIT  seconds to wait for the origin to reach readyState complete
//                (default 20)
//
// Exit status: 0 read, 4 the server says the URL is absent, 1 anything else.
import { chromium } from "playwright";
import fs from "node:fs";

const [, , url, out, referer] = process.argv;
if (!url || !out) {
  console.error("usage: fetch.mjs URL OUT [REFERER]");
  process.exit(2);
}
const origin = new URL(referer || url).origin;
const waitS = Number(process.env.CHROME_WAIT || 20);

const browser = await chromium.launch({
  headless: true,
  channel: "chromium",
  args: ["--no-sandbox", "--disable-dev-shm-usage"],
});
let code = 1;
try {
  const version = browser.version();
  const ua =
    process.env.CHROME_UA ||
    `Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${version} Safari/537.36`;

  const context = await browser.newContext({
    userAgent: ua,
    locale: "en-US",
    timezoneId: "UTC",
    viewport: { width: 1366, height: 768 },
  });
  const page = await context.newPage();

  try {
    await page.goto(origin, { waitUntil: "domcontentloaded", timeout: 60000 });
    const deadline = Date.now() + waitS * 1000;
    while (Date.now() < deadline) {
      const ready = await page.evaluate(() => document.readyState).catch(() => "");
      if (ready === "complete") break;
      await page.waitForTimeout(250);
    }
  } catch (e) {
    console.error(`chromium: origin visit: ${e.message}`);
  }

  const r = await page.evaluate(async (u) => {
    const resp = await fetch(u, { credentials: "include", cache: "no-store" });
    if (resp.status !== 200) return { status: resp.status };
    const buf = new Uint8Array(await resp.arrayBuffer());
    let s = "";
    for (let i = 0; i < buf.length; i += 0x8000) {
      s += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));
    }
    return { status: 200, b64: btoa(s) };
  }, url);

  if (r.status === 404 || r.status === 410) {
    console.error(`chromium: status ${r.status}`);
    code = 4;
  } else if (r.status !== 200 || !r.b64) {
    console.error(`chromium: status ${r.status}`);
    code = 1;
  } else {
    fs.writeFileSync(out, Buffer.from(r.b64, "base64"));
    code = 0;
  }
} finally {
  await browser.close();
}
process.exit(code);
