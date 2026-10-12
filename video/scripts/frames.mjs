#!/usr/bin/env node
// Puts each clip scene (types "device" and "terminal") of the project in its frame, at the length retime.mjs gave
// it, and writes out/<scene id>.mp4. A scene's props:
//   clip   "app" / "install" (raw/app.mov or raw/install.mp4 when you made them, else the committed clips in
//          reference/), or a path relative to video/ (a sibling <name>.json may hold {"demoStartsAt": seconds})
//   frame  "macbook" (device only: frame-app.sh), "window" (frame-terminal.sh) or "none"
//   speed  playback speed of the clip (default 1)
// Usage: node scripts/frames.mjs        Env: VIDEO_PROJECT, VIDEO_THEME, VIDEO_FORMAT
import {execFileSync} from 'node:child_process';
import {existsSync, readFileSync} from 'node:fs';
import {join} from 'node:path';
import {loadProject, root, shellEnv} from './project.mjs';

process.chdir(root);
const p = loadProject();
const timeline = JSON.parse(readFileSync('out/timeline.json', 'utf8'));
const env = {...process.env};
for (const line of shellEnv(p).split('\n')) {
  const [, k, v] = line.match(/^export (\w+)='(.*)'$/);
  env[k] = v;
}
// "app" and "install" are the clips this repo records. The terminal comes in four variants (scripts/record-terminal.sh):
// light or dark to suit the theme, landscape or portrait to suit the format; a missing variant falls back to the plain one.
const narrow = env.VIDEO_NARROW === '1';
const variant = (base) => (base === 'install' ? `install${env.TERMINAL_MODE === 'dark' ? '-dark' : ''}${narrow ? '-portrait' : ''}` : base);
const named = (name) => [`raw/${name}.${name === 'app' ? 'mov' : 'mp4'}`, `reference/${name}.mp4`];
function resolveClip(clip) {
  if (!['app', 'install'].includes(clip)) return clip;
  for (const name of [variant(clip), clip]) {
    const found = named(name).find(existsSync);
    if (found) {
      if (name !== variant(clip)) console.warn(`  note: no ${variant(clip)} clip yet; using ${name} (record it with scripts/record-terminal.sh)`);
      return found;
    }
  }
}

for (const scene of p.scenes.filter((s) => s.kind === 'clip')) {
  const length = timeline.scenes[scene.id].length;
  const clip = resolveClip(scene.props.clip);
  if (!clip || !existsSync(clip)) throw new Error(`scene "${scene.id}": no clip "${scene.props.clip}" (record it, or see reference/)`);
  const out = join('out', `${scene.id}.mp4`);
  const frame = scene.props.frame ?? (scene.type === 'device' ? 'macbook' : 'window');
  const speed = String(scene.props.speed ?? 1);
  if (frame === 'macbook') {
    const meta = clip.replace(/\.[^.]+$/, '.json');
    const start = existsSync(meta) ? JSON.parse(readFileSync(meta, 'utf8')).demoStartsAt ?? 0 : 0;
    execFileSync('scripts/frame-app.sh', [clip, out, String(start), String(length)], {env: {...env, SPEED: speed}, stdio: 'inherit'});
  } else if (frame === 'window') {
    execFileSync('scripts/frame-terminal.sh', [clip, out, String(length)], {env, stdio: 'inherit'});
  } else {
    // No frame: the clip as it is, trimmed to the scene (assemble.mjs fits it to the format).
    execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-i', clip, '-t', String(length), '-an', '-c:v', 'libx264', '-crf', '17', out], {stdio: 'inherit'});
    console.log(`wrote ${out}`);
  }
}
