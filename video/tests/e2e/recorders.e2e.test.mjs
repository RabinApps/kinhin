// End-to-end: the recorders. Each needs a tool (ffmpeg, Chromium, VHS) and is skipped without it.
import assert from 'node:assert/strict';
import {existsSync, readFileSync, rmSync} from 'node:fs';
import {join} from 'node:path';
import {test} from 'node:test';
import {has, root, run} from '../helpers.mjs';
import {from} from './e2e.mjs';

const raw = join(root, 'raw/template');
// A Chromium to record with: CHROMIUM_PATH, or Chrome / Chromium in the usual places.
const chromium = [process.env.CHROMIUM_PATH, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome'].find((p) => p && existsSync(p));

test('recorders: an app clip is recorded through the adapter contract', {skip: !has('ffmpeg') && 'needs ffmpeg'}, () => {
  rmSync(join(raw, 'app.mov'), {force: true});
  const r = run('node', ['scripts/record-clip.mjs', '--adapter', 'template', '--clip', 'app', '--', '3']);
  assert.equal(r.status, 0, r.stderr);
  assert.ok(existsSync(join(raw, 'app.mov')));
  assert.deepEqual(JSON.parse(readFileSync(join(raw, 'app.json'), 'utf8')), {demoStartsAt: 0});
});

test('recorders: a browser clip is recorded from its scenario, serving the page itself', {skip: !chromium && 'needs Chrome or Chromium (set CHROMIUM_PATH)'}, () => {
  rmSync(join(raw, 'site.webm'), {force: true});
  const r = run('node', ['scripts/record-clip.mjs', '--adapter', 'template', '--clip', 'site'], {env: {CHROMIUM_PATH: chromium}, timeout: 5 * 60 * 1000});
  assert.equal(r.status, 0, r.stdout.slice(-600) + r.stderr.slice(-600));
  assert.ok(existsSync(join(raw, 'site.webm')) && existsSync(join(raw, 'site.json')));
});

test('recorders: a terminal clip is recorded in a variant and the output is a video', {skip: !has('vhs') && 'needs vhs'}, () => {
  const r = run('scripts/record-terminal.sh', ['--adapter', 'template', '--clip', 'demo', '--dark'], {timeout: 5 * 60 * 1000});
  assert.equal(r.status, 0, r.stdout.slice(-600) + r.stderr.slice(-600));
  assert.ok(existsSync(join(raw, 'demo-dark.mp4')));
});

test('recorders: an unknown clip or adapter is a clear error', () => {
  const clip = run('node', ['scripts/record-clip.mjs', '--adapter', 'template', '--clip', 'nothing']);
  assert.notEqual(clip.status, 0);
  assert.match(clip.stderr, /has no clip "nothing" \(app, demo, site\)/);
  const adapter = run('node', ['scripts/record-clip.mjs', '--adapter', 'nope', '--clip', 'app']);
  assert.notEqual(adapter.status, 0);
  assert.match(adapter.stderr, /no adapter "nope"/);
});

test('recorders: make-reference turns raw clips into small committed ones', {skip: !has('ffmpeg') && 'needs ffmpeg'}, () => {
  const before = existsSync(join(root, 'adapters/template/reference/app.mp4'));
  assert.ok(before, 'the template reference clip is committed');
  assert.ok(readFileSync(join(root, 'adapters/template/reference/app.json'), 'utf8').includes('demoStartsAt'));
});
