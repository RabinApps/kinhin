// Records a scripted browser session of a web product as a video (Playwright + Chromium).
// Runs anywhere Node and Chromium do: a Mac, Linux, or inside a container (see scripts/record-web.sh).
//
// Usage: node sources/web/record.mjs <scenario.json> [out.webm]
// Env:   BASE_URL       prefix for relative `goto` urls (overrides the scenario's baseUrl)
//        CHROMIUM_PATH  use this Chromium binary instead of Playwright's own download
//        PACE           multiplies every pause and move (default 1; 0.5 is twice as fast)
//
// A scenario is JSON (see adapters/kinhin/scenarios/site.json and docs/videos-for-your-project.md):
//   { "baseUrl": "...", "viewport": {"width":1920,"height":1080}, "colorScheme": "light", "steps": [ ... ] }
// Steps: goto, wait, move, hover, click, type, press, scroll. The page gets a visible cursor, because
// Playwright's recording does not draw one.
import { chromium } from 'playwright-core';
import { mkdirSync, readFileSync, renameSync, rmSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

const [scenarioPath, outPath = 'raw/web.webm'] = process.argv.slice(2);
if (!scenarioPath) {
  console.error('usage: node sources/web/record.mjs <scenario.json> [out.webm]');
  process.exit(2);
}

const scenario = JSON.parse(readFileSync(scenarioPath, 'utf8'));
const baseUrl = (process.env.BASE_URL ?? scenario.baseUrl ?? '').replace(/\/$/, '');
const viewport = scenario.viewport ?? { width: 1920, height: 1080 };
const pace = Number(process.env.PACE ?? 1);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms * pace));

const CURSOR = () => {
  const make = () => {
    if (document.getElementById('__cursor')) return;
    const cursor = document.createElement('div');
    cursor.id = '__cursor';
    Object.assign(cursor.style, {
      position: 'fixed', zIndex: '2147483647', pointerEvents: 'none', left: '0', top: '0',
      width: '26px', height: '26px', marginLeft: '-13px', marginTop: '-13px', borderRadius: '50%',
      background: 'rgba(0,0,0,0.85)', border: '3px solid #fff', boxShadow: '0 1px 6px rgba(0,0,0,0.45)',
      transition: 'transform 120ms ease', transform: 'scale(1)',
    });
    document.documentElement.appendChild(cursor);
    addEventListener('mousemove', (e) => { cursor.style.left = e.clientX + 'px'; cursor.style.top = e.clientY + 'px'; }, true);
    addEventListener('mousedown', () => { cursor.style.transform = 'scale(0.7)'; }, true);
    addEventListener('mouseup', () => { cursor.style.transform = 'scale(1)'; }, true);
  };
  if (document.documentElement) make(); else addEventListener('DOMContentLoaded', make);
};

const workDir = mkdtempSync(join(tmpdir(), 'kinhin-web-'));
const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_PATH || undefined,
  args: ['--hide-scrollbars'],
});
const context = await browser.newContext({
  viewport,
  deviceScaleFactor: 1,
  colorScheme: scenario.colorScheme ?? 'light',
  recordVideo: { dir: workDir, size: viewport },
});
await context.addInitScript(CURSOR);
const page = await context.newPage();
let mouse = { x: viewport.width / 2, y: viewport.height / 2 };

const url = (target) => (/^https?:/.test(target) ? target : baseUrl + target);

async function moveTo(x, y, steps = 30) {
  await page.mouse.move(x, y, { steps: Math.max(1, Math.round(steps)) });
  mouse = { x, y };
}

async function target(step) {
  const locator = step.text ? page.getByText(step.text, { exact: false }).first() : page.locator(step.selector).first();
  await locator.scrollIntoViewIfNeeded();
  const box = await locator.boundingBox();
  if (!box) throw new Error(`no box for ${JSON.stringify(step)}`);
  return { locator, x: box.x + box.width / 2, y: box.y + box.height / 2 };
}

const actions = {
  async goto(step) {
    await page.goto(url(step.url), { waitUntil: 'load' });
    await sleep(step.settleMs ?? 600);
  },
  async wait(step) { await sleep(step.ms ?? 1000); },
  async move(step) {
    if (step.selector || step.text) { const t = await target(step); await moveTo(t.x, t.y); }
    else await moveTo(step.x, step.y);
  },
  async hover(step) {
    const t = await target(step);
    await moveTo(t.x, t.y);
    await sleep(step.ms ?? 600);
  },
  async click(step) {
    const t = await target(step);
    await moveTo(t.x, t.y);
    await sleep(250);
    await page.mouse.down();
    await sleep(90);
    await page.mouse.up();
    await sleep(step.settleMs ?? 800);
  },
  async type(step) {
    const t = await target(step);
    await moveTo(t.x, t.y);
    await page.mouse.click(t.x, t.y);
    await page.keyboard.type(step.text, { delay: (step.delayMs ?? 70) * pace });
    await sleep(400);
  },
  async press(step) { await page.keyboard.press(step.key); await sleep(step.settleMs ?? 400); },
  // Smooth scroll by `y` pixels (or to a selector) over `ms`, eased.
  async scroll(step) {
    const ms = (step.ms ?? 1500) * pace;
    await page.evaluate(async ({ by, selector, ms }) => {
      const from = scrollY;
      const to = selector
        ? document.querySelector(selector).getBoundingClientRect().top + scrollY - innerHeight / 3
        : from + by;
      const start = performance.now();
      await new Promise((resolve) => {
        const tick = (now) => {
          const t = Math.min(1, (now - start) / ms);
          const eased = t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
          scrollTo(0, from + (to - from) * eased);
          t < 1 ? requestAnimationFrame(tick) : resolve();
        };
        requestAnimationFrame(tick);
      });
    }, { by: step.y ?? 0, selector: step.selector ?? null, ms });
    await sleep(step.settleMs ?? 400);
  },
};

let failure = null;
try {
  for (const [index, step] of scenario.steps.entries()) {
    const run = actions[step.do];
    if (!run) throw new Error(`step ${index}: unknown action "${step.do}" (use ${Object.keys(actions).join(', ')})`);
    console.log(`step ${index + 1}/${scenario.steps.length}: ${step.do}${step.url ? ' ' + step.url : step.selector ? ' ' + step.selector : step.text ? ' "' + step.text + '"' : ''}`);
    await run(step);
  }
} catch (error) {
  failure = error;
}

const video = page.video();
await context.close(); // flushes the video file
await browser.close();
if (failure) {
  rmSync(workDir, { recursive: true, force: true });
  console.error(`scenario failed: ${failure.message}`);
  process.exit(1);
}
mkdirSync(dirname(outPath), { recursive: true });
renameSync(await video.path(), outPath);
rmSync(workDir, { recursive: true, force: true });
console.log(`wrote ${outPath}`);
