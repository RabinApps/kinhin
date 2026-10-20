#!/usr/bin/env node
// Puts each clip scene (types "device" and "terminal") of the project in its frame, at the length retime.mjs gave
// it, and writes out/.work/<scene id>.mp4. A scene's props:
//   clip   a clip of the project's adapter (see scripts/adapter.mjs), or a path relative to video/
//   frame  "macbook" (device only: frame-app.sh), "window" (frame-terminal.sh) or "none"
//   speed  playback speed of the clip (default 1)
//   camera, focus, cursor  guided camera work on the recording itself: eased zoom and pan, a spotlight, a cursor with click
//            rings (scripts/camera.mjs). It is drawn first, so the frame below holds still while the picture inside it moves.
//   screens  instead of a clip: a list of PNG paths (relative to video/), shown as a cross-fading slideshow of the
//            scene's length (opt-in; a scene without it is unchanged). `{platform}` in a path becomes the look's platform
//            (ios or android, from VIDEO_PLATFORM; default ios). The screens sit in a phone frame (`frame`: iphone,
//            android or none; default follows the platform). `hold` seconds per image (default 2.5).
// Usage: node scripts/frames.mjs        Env: VIDEO_PROJECT, VIDEO_THEME, VIDEO_FORMAT
import {execFileSync} from 'node:child_process';
import {existsSync, mkdirSync, readFileSync} from 'node:fs';
import {join} from 'node:path';
import {loadAdapter, resolveClip as resolveClip_} from './adapter.mjs';
import {applyCamera, wantsCamera} from './camera.mjs';
import {slideshow} from './slideshow.mjs';
import {loadProject, root, shellEnv} from './project.mjs';

process.chdir(root);
const p = loadProject();
mkdirSync('out/.work', {recursive: true});
const timeline = JSON.parse(readFileSync('out/.work/timeline.json', 'utf8'));
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
  if (Array.isArray(scene.props.screens)) {
    const platform = env.VIDEO_PLATFORM || 'ios';
    const images = scene.props.screens.map((path) => path.replaceAll('{platform}', platform));
    const frame = scene.props.frame ?? (platform === 'android' ? 'android' : 'iphone');
    slideshow(images, length, join('out/.work', `${scene.id}.mp4`), {
      hold: scene.props.hold ?? 2.5,
      frame,
      canvasW: Number(env.VIDEO_W ?? 1920),
      canvasH: Number(env.VIDEO_H ?? 1080),
    });
    continue;
  }
  const found = resolveClip(scene.props.clip);
  if (!found) throw new Error(`scene "${scene.id}": no clip "${scene.props.clip}"${adapter ? ` in the ${adapter.name} adapter (record it, or add it to ${process.env.VIDEO_SOURCE ? '.kinhin/videos/' : ''}adapters/${adapter.name}/reference/)` : ' (the project has no adapter; give a path)'}`);
  let clip = found.file;
  const out = join('out/.work', `${scene.id}.mp4`);
  // An app recording defaults to the laptop; a terminal or a browser session to a window.
  const frame = scene.props.frame ?? (found.kind === 'app' || (found.kind === 'path' && scene.type === 'device') ? 'macbook' : 'window');
  let speed = String(scene.props.speed ?? 1);
  let start = found.meta && existsSync(found.meta) ? JSON.parse(readFileSync(found.meta, 'utf8')).demoStartsAt ?? 0 : 0;
  const frameEnv = {...env};
  if (wantsCamera(scene.props)) {
    // Only the laptop frame starts the clip late and changes its speed. The camera pass applies both, so what the frame gets
    // is a clip of exactly the scene's length (and, for the laptop, with the window's toolbar buttons already covered).
    const laptop = frame === 'macbook';
    const cameraClip = join('out/.work', `${scene.id}-camera.mp4`);
    applyCamera({clip, out: cameraClip, props: scene.props, start: laptop ? start : 0, speed: laptop ? Number(speed) : 1, length, cover: laptop ? env.BAR_COLOR : undefined});
    clip = cameraClip;
    start = 0;
    speed = '1';
    if (laptop) frameEnv.COVER = '0';
  }
  if (frame === 'macbook') {
    execFileSync('scripts/frame-app.sh', [clip, out, String(start), String(length)], {env: {...frameEnv, SPEED: speed}, stdio: 'inherit'});
  } else if (frame === 'window') {
    execFileSync('scripts/frame-terminal.sh', [clip, out, String(length)], {env, stdio: 'inherit'});
  } else {
    // No frame: the clip as it is, trimmed to the scene (assemble.mjs fits it to the format).
    execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-i', clip, '-t', String(length), '-an', '-c:v', 'libx264', '-crf', '17', out], {stdio: 'inherit'});
    console.log(`wrote ${out}`);
  }
}
