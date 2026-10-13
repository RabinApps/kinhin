// Shared by the unit and e2e tests.
import {execFileSync, spawnSync} from 'node:child_process';
import {existsSync, readFileSync, readdirSync, statSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const repo = resolve(root, '..');
export const has = (cmd) => spawnSync('which', [cmd]).status === 0;

/** Every project file under video/script/, as names ("launch", "examples/hello"). */
export function projectNames(dir = join(root, 'script'), prefix = '') {
  return readdirSync(dir).flatMap((n) => (statSync(join(dir, n)).isDirectory() ? projectNames(join(dir, n), `${prefix}${n}/`) : n.endsWith('.json') ? [`${prefix}${n.replace(/\.json$/, '')}`] : []));
}

export const themeNames = () => readdirSync(join(root, 'themes')).filter((f) => f.endsWith('.json')).map((f) => f.replace(/\.json$/, ''));
export const readJson = (file) => JSON.parse(readFileSync(file, 'utf8'));

/** Runs a script from video/ and returns {status, stdout, stderr} without throwing. */
export function run(cmd, args = [], {env = {}, cwd = root, timeout = 600000} = {}) {
  const r = spawnSync(cmd, args, {cwd, env: {...process.env, ...env}, encoding: 'utf8', timeout, maxBuffer: 64 << 20});
  return {status: r.status, stdout: r.stdout ?? '', stderr: r.stderr ?? ''};
}

/** A tiny finished video (with audio, captions, poster and hero) for the verifier tests, made with ffmpeg. */
export function makeFixtureVideo(dir, name, {seconds = 3, width = 320, height = 180, black = false, silent = false, loud = false, srt = true, poster = true} = {}) {
  const out = join(dir, `${name}.mp4`);
  const video = black ? `color=c=black:s=${width}x${height}:d=${seconds}` : `testsrc2=s=${width}x${height}:d=${seconds}:r=30`;
  const args = ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', video];
  if (!silent) args.push('-f', 'lavfi', '-i', `sine=frequency=330:duration=${seconds}`, '-af', loud ? 'volume=0.9' : 'volume=0.05');
  args.push('-c:v', 'libx264', '-pix_fmt', 'yuv420p', ...(silent ? ['-an'] : ['-c:a', 'aac']), '-shortest', out);
  execFileSync('ffmpeg', args);
  if (srt) execFileSync('node', ['-e', `require('fs').writeFileSync(${JSON.stringify(join(dir, name + '.srt'))}, '1\\n00:00:00,500 --> 00:00:02,000\\nhello\\n')`]);
  if (poster) {
    execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', `testsrc2=s=${width}x${height}:d=1`, '-frames:v', '1', join(dir, `${name}-poster.png`)]);
    execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', `testsrc2=s=${width}x${height}:d=3:r=10`, join(dir, `${name}-hero.gif`)]);
  }
  return out;
}
