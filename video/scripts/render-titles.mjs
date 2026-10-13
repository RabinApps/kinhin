#!/usr/bin/env node
// Renders every canvas scene (title, queue, parallel, map, outro, statement) of the project headlessly: for each
// one it starts the Motion Canvas editor with that scene selected, drives the Render button with Playwright's
// Chromium, and moves the result to raw/scenes/<project>/<id>.mp4. The frame size follows the project's format.
// Runs the same on a laptop and in the container (scripts/build.sh --container).
//
// A scene is re-rendered only when something that shapes it changed: its type and props, its length, the theme, the
// format, or the scene sources (raw/scenes/<project>/.cache.json holds the keys). RENDER_FORCE=1 renders everything.
//
// Usage: node scripts/render-titles.mjs [scene ids...]      (default: every canvas scene)
// Env:   VIDEO_PROJECT, VIDEO_THEME, VIDEO_FORMAT  see scripts/project.mjs
//        CHROMIUM_PATH  Chromium/Chrome binary to use instead of Playwright's own download
//        RENDER_TIMEOUT_S  give up after this many seconds per scene (default 600)
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {chromium} from 'playwright-core';
import {loadProject, loadThemes, root, userThemeNames} from './project.mjs';

process.chdir(root);
const {scenes, stem, slug, format, theme, project, file} = loadProject();
// The editor bundles video/script/ at build time. A project from your own repository (VIDEO_SOURCE) is not there, so hand
// it over as .generated/<slug>.json (git-ignored), which src/config.ts reads first.
if (!file.startsWith(join(root, 'script') + '/')) {
  mkdirSync(join(root, '.generated'), {recursive: true});
  writeFileSync(join(root, '.generated', `${slug}.json`), JSON.stringify(project));
}
// Your own themes (.kinhin/videos/themes/) reach the editor the same way, already resolved (any "extends" applied).
{
  const dir = join(root, '.generated', 'themes');
  rmSync(dir, {recursive: true, force: true});
  const names = userThemeNames();
  if (names.length) {
    const all = loadThemes();
    mkdirSync(dir, {recursive: true});
    for (const name of names) writeFileSync(join(dir, `${name}.json`), JSON.stringify(all[name]));
  }
}
const wanted = process.argv.slice(2);
const targets = scenes.filter((s) => s.kind === 'canvas' && (!wanted.length || wanted.includes(s.id)));
const timeout = Number(process.env.RENDER_TIMEOUT_S ?? 600) * 1000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// What a scene's picture depends on, hashed: the sources (everything under src/ except the generated timing.ts, which
// holds every scene's length, and shared/), the scene itself and its own length, the theme and the format.
const walk = (dir) => readdirSync(dir, {withFileTypes: true}).flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]));
const sourceHash = createHash('sha256');
for (const f of [...walk('src'), ...walk('shared')].sort()) if (!f.endsWith('src/timing.ts') && !f.endsWith('.meta')) sourceHash.update(f).update(readFileSync(f));
let timing = {};
try {
  timing = JSON.parse(readFileSync('out/.work/timeline.json', 'utf8')); // missing when scenes are rendered before a retime: minLength then
} catch {}
const lengthOf = (scene) => timing.scenes?.[scene.id]?.length ?? scene.minLength;
const keyOf = (scene) =>
  createHash('sha256').update(sourceHash.copy().digest('hex')).update(JSON.stringify({type: scene.type, props: scene.props, length: lengthOf(scene), theme, format})).digest('hex').slice(0, 20);
const cacheFile = join('raw/scenes', slug, '.cache.json');
const cache = existsSync(cacheFile) ? JSON.parse(readFileSync(cacheFile, 'utf8')) : {};

// The editor's project file holds the frame size and exporter; make them match the format and the ffmpeg exporter.
const metaPath = 'src/titles.meta';
const meta = JSON.parse(readFileSync(metaPath, 'utf8'));
meta.shared.size = {x: format.width, y: format.height};
meta.rendering.fps = 30;
meta.rendering.exporter = {name: '@motion-canvas/ffmpeg', options: {fastStart: true, includeAudio: false}};
writeFileSync(metaPath, JSON.stringify(meta, null, 2) + '\n');

async function waitForServer(port) {
  for (let i = 0; i < 120; i++) {
    try {
      if ((await fetch(`http://127.0.0.1:${port}/`)).ok) return;
    } catch {}
    await sleep(500);
  }
  throw new Error('the Motion Canvas editor did not start');
}

async function render(scene, browser, port) {
  const produced = join('output', 'titles.mp4');
  rmSync(produced, {force: true});
  // Vite is started directly (not through npx) so that killing it really stops the server.
  const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', String(port), '--strictPort'], {
    env: {...process.env, VITE_SCENE_ID: scene.id, VITE_VIDEO_PROJECT: stem, VITE_VIDEO_THEME: process.env.VIDEO_THEME ?? '', VITE_VIDEO_FORMAT: process.env.VIDEO_FORMAT ?? ''},
    stdio: 'ignore',
  });
  try {
    await waitForServer(port);
    const page = await browser.newPage({viewport: {width: 1600, height: 900}});
    page.on('pageerror', (e) => console.error(`  [${scene.id}] page error: ${e.message}`));
    await page.goto(`http://127.0.0.1:${port}/`);
    const button = page.getByRole('button', {name: 'Render', exact: true});
    await button.waitFor({timeout: 60000});
    await button.click();
    // While it renders the button reads "Abort"; it returns to "Render" when the file is written.
    await page.getByRole('button', {name: 'Abort'}).waitFor({timeout: 30000});
    await button.waitFor({timeout});
    await page.close();
    for (let i = 0; i < 20 && !existsSync(produced); i++) await sleep(500);
    if (!existsSync(produced) || statSync(produced).size === 0) throw new Error(`no ${produced} was written`);
    const out = join('raw/scenes', slug, `${scene.id}.mp4`);
    mkdirSync(join('raw/scenes', slug), {recursive: true});
    copyFileSync(produced, out); // not a rename: raw/ may be another filesystem (a bind mount)
    rmSync(produced);
    console.log(`rendered ${out}`);
  } finally {
    server.kill('SIGTERM');
    await sleep(500);
  }
}

const browser = await chromium.launch({executablePath: process.env.CHROMIUM_PATH || undefined, args: ['--no-sandbox']});
try {
  for (const [i, scene] of targets.entries()) {
    const key = keyOf(scene);
    const out = join('raw/scenes', slug, `${scene.id}.mp4`);
    if (!process.env.RENDER_FORCE && cache[scene.id] === key && existsSync(out)) {
      console.log(`cached   ${out}`);
      continue;
    }
    await render(scene, browser, 9317 + i);
    cache[scene.id] = key;
    mkdirSync(join('raw/scenes', slug), {recursive: true});
    writeFileSync(cacheFile, JSON.stringify(cache, null, 2) + '\n');
  }
} finally {
  await browser.close();
}
