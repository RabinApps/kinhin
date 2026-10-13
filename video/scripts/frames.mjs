#!/usr/bin/env node
// Puts each clip scene (types "device" and "terminal") of the project in its frame, at the length retime.mjs gave
// it, and writes out/<scene id>.mp4. A scene's props:
//   clip   a clip of the project's adapter (see scripts/adapter.mjs), or a path relative to video/
//   frame  "macbook" (device only: frame-app.sh), "window" (frame-terminal.sh) or "none"
//   speed  playback speed of the clip (default 1)
// Usage: node scripts/frames.mjs        Env: VIDEO_PROJECT, VIDEO_THEME, VIDEO_FORMAT
import {execFileSync} from 'node:child_process';
import {existsSync, readFileSync} from 'node:fs';
import {join} from 'node:path';
import {loadAdapter, resolveClip as resolveClip_} from './adapter.mjs';
import {loadProject, root, shellEnv} from './project.mjs';

process.chdir(root);
const p = loadProject();
const timeline = JSON.parse(readFileSync('out/timeline.json', 'utf8'));
const env = {...process.env};
for (const line of shellEnv(p).split('\n')) {
  const [, k, v] = line.match(/^export (\w+)='(.*)'$/);
  env[k] = v;
}
// A clip is a name from the project's adapter (adapters/<name>/adapter.json: your recording in raw/<adapter>/ first,
// else the committed reference clip; terminal clips use the variant that suits the theme and the frame), or a path
// relative to video/ (a sibling <name>.json may hold {"demoStartsAt": seconds}).
const adapter = p.adapter ? loadAdapter(p.adapter) : null;
const dark = env.TERMINAL_MODE === 'dark';
const narrow = env.VIDEO_NARROW === '1';
function resolveClip(clip) {
  const found = adapter ? resolveClip_(adapter, clip, {dark, narrow}) : null;
  if (found) {
    if (found.note) console.warn(`  note: ${found.note} (record it with scripts/record-terminal.sh)`);
    return {kind: found.kind, file: found.file, meta: found.meta};
  }
  if (existsSync(clip)) return {kind: 'path', file: clip, meta: clip.replace(/\.[^.]+$/, '.json')};
  return null;
}

for (const scene of p.scenes.filter((s) => s.kind === 'clip')) {
  const length = timeline.scenes[scene.id].length;
  const found = resolveClip(scene.props.clip);
  if (!found) throw new Error(`scene "${scene.id}": no clip "${scene.props.clip}"${adapter ? ` in the ${adapter.name} adapter (record it, or add it to ${process.env.VIDEO_SOURCE ? '.kinhin/videos/' : ''}adapters/${adapter.name}/reference/)` : ' (the project has no adapter; give a path)'}`);
  const clip = found.file;
  const out = join('out', `${scene.id}.mp4`);
  // An app recording defaults to the laptop; a terminal or a browser session to a window.
  const frame = scene.props.frame ?? (found.kind === 'app' || (found.kind === 'path' && scene.type === 'device') ? 'macbook' : 'window');
  const speed = String(scene.props.speed ?? 1);
  if (frame === 'macbook') {
    const start = found.meta && existsSync(found.meta) ? JSON.parse(readFileSync(found.meta, 'utf8')).demoStartsAt ?? 0 : 0;
    execFileSync('scripts/frame-app.sh', [clip, out, String(start), String(length)], {env: {...env, SPEED: speed}, stdio: 'inherit'});
  } else if (frame === 'window') {
    execFileSync('scripts/frame-terminal.sh', [clip, out, String(length)], {env, stdio: 'inherit'});
  } else {
    // No frame: the clip as it is, trimmed to the scene (assemble.mjs fits it to the format).
    execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-i', clip, '-t', String(length), '-an', '-c:v', 'libx264', '-crf', '17', out], {stdio: 'inherit'});
    console.log(`wrote ${out}`);
  }
}
