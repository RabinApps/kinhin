// Helpers for the e2e tests: real builds, in a container by default, judged by scripts/verify.mjs (the same checker CI uses).
//
// Env: E2E_TIER     smoke (default, a few minutes) | standard (every theme, format and scene type) | full (everything,
//                   both container runtimes)
//      E2E_MODE     container (default) | host (this machine's Node, ffmpeg with libass and Chromium)
//      E2E_RUNTIME  container | docker (default: Apple's container if running, else Docker)
import {existsSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {verifyVideo} from '../../scripts/verify.mjs';
import {has, root, run} from '../helpers.mjs';

export const tier = process.env.E2E_TIER || 'smoke';
const rank = {smoke: 0, standard: 1, full: 2};
/** Options for `test()`: skip unless the tier is at least `min`, or a runtime is missing. */
export function from(min) {
  if (rank[tier] < rank[min]) return {skip: `tier ${tier} < ${min} (E2E_TIER=${min})`};
  if (process.env.E2E_MODE === 'host') return {};
  const runtime = process.env.E2E_RUNTIME;
  const ok = runtime ? has(runtime) : has('container') || has('docker');
  return ok ? {} : {skip: 'no container runtime (Apple container or Docker)'};
}

export const modeFlags = () => (process.env.E2E_MODE === 'host' ? [] : ['--container', ...(process.env.E2E_RUNTIME ? ['--runtime', process.env.E2E_RUNTIME] : [])]);

/** Runs scripts/build.sh and returns {status, stdout, stderr, name}; `name` is the output's base name when it succeeded. */
export function build(args, {env = {}} = {}) {
  const r = run('scripts/build.sh', [...modeFlags(), ...args], {env: {NO_MUSIC: '', ...env}, timeout: 25 * 60 * 1000});
  const m = r.stdout.match(/wrote out\/([\w.-]+)\.mp4 \(/);
  return {...r, name: m?.[1]};
}

/** Verifies a finished build against its timeline. Returns the verifier's {failures, facts}. */
export function check(name, options = {}) {
  const timeline = JSON.parse(readFileSync(join(root, 'out/timeline.json'), 'utf8'));
  return verifyVideo(join(root, `out/${name}.mp4`), {timeline: timeline.outName === name ? timeline : undefined, ...options});
}

/** Writes a throwaway project into video/script/examples/ (the editor only sees projects there); returns its name and a cleanup. */
export function tempProject(project) {
  const id = `tmp-e2e-${process.pid}-${Math.random().toString(36).slice(2, 7)}`;
  const file = join(root, 'script/examples', `${id}.json`);
  writeFileSync(file, JSON.stringify(project, null, 2));
  return {name: `examples/${id}`, slug: `examples-${id}`, file, cleanup: () => { rmSync(file, {force: true}); rmSync(join(root, 'raw/scenes', `examples-${id}`), {recursive: true, force: true}); }};
}

export const canvasScenes = (project) => project.scenes.length;
export {existsSync, has, root, run};
