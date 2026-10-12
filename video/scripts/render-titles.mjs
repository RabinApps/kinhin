#!/usr/bin/env node
// Renders the Motion Canvas title projects headlessly: starts the editor, drives its Render button with
// Playwright's Chromium, and moves the result to raw/<project>.mp4. This replaces clicking Render by hand,
// so it runs the same on a laptop and in the container (scripts/build.sh --container).
//
// Usage: node scripts/render-titles.mjs [opening closing]        (default: both)
// Env:   CHROMIUM_PATH  Chromium/Chrome binary to use instead of Playwright's own download
//        RENDER_TIMEOUT_S  give up after this many seconds per project (default 600)
import {spawn} from 'node:child_process';
import {copyFileSync, existsSync, mkdirSync, rmSync, statSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright-core';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
process.chdir(root);
const projects = process.argv.slice(2).length ? process.argv.slice(2) : ['opening', 'closing'];
const timeout = Number(process.env.RENDER_TIMEOUT_S ?? 600) * 1000;
const basePort = 9317;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitForServer(port) {
  for (let i = 0; i < 120; i++) {
    try {
      if ((await fetch(`http://127.0.0.1:${port}/`)).ok) return;
    } catch {}
    await sleep(500);
  }
  throw new Error('the Motion Canvas editor did not start');
}

async function render(project, browser, port) {
  const produced = join('output', `${project}.mp4`);
  rmSync(produced, {force: true});
  // Vite is started directly (not through npx) so that killing it really stops the server.
  const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', String(port), '--strictPort'], {
    env: {...process.env, VIDEO_PROJECT: project},
    stdio: 'ignore',
  });
  try {
    await waitForServer(port);
    const page = await browser.newPage({viewport: {width: 1600, height: 900}});
    page.on('pageerror', (e) => console.error(`  [${project}] page error: ${e.message}`));
    await page.goto(`http://127.0.0.1:${port}/`);
    const button = page.getByRole('button', {name: 'Render', exact: true});
    await button.waitFor({timeout: 60000});
    await button.click();
    // While it renders the button reads "Abort"; it returns to "Render" when the file is written.
    await page.getByRole('button', {name: 'Abort'}).waitFor({timeout: 30000});
    await button.waitFor({timeout: timeout});
    await page.close();
    for (let i = 0; i < 20 && !existsSync(produced); i++) await sleep(500);
    if (!existsSync(produced) || statSync(produced).size === 0) throw new Error(`no ${produced} was written`);
    mkdirSync('raw', {recursive: true});
    copyFileSync(produced, join('raw', `${project}.mp4`)); // not a rename: raw/ may be another filesystem (a bind mount)
    rmSync(produced);
    console.log(`rendered raw/${project}.mp4`);
  } finally {
    server.kill('SIGTERM');
    await sleep(500);
  }
}

const browser = await chromium.launch({executablePath: process.env.CHROMIUM_PATH || undefined, args: ['--no-sandbox']});
try {
  for (const [i, p] of projects.entries()) await render(p, browser, basePort + i);
} finally {
  await browser.close();
}
