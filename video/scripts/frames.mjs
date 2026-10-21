#!/usr/bin/env node
// Puts each clip scene (types "device", "terminal" and "split") of the project in its frame, at the length retime.mjs gave
// it, and writes out/.work/<scene id>.mp4. A scene's props:
//   clip   a clip of the project's adapter (see scripts/adapter.mjs), or a path relative to video/
//   frame  "macbook" (device only: frame-app.sh), "window" (frame-terminal.sh) or "none"
//   speed  playback speed of the clip (default 1), or a list of {until, speed} segments for speed ramps (scripts/speed.mjs)
//   camera, focus, cursor  guided camera work on the recording itself: eased zoom and pan, a spotlight, a cursor with click
//            rings (scripts/camera.mjs). It is drawn first, so the frame below holds still while the picture inside it moves.
//            Positions may be names from the clip's `targets` in its adapter.
//   A "split" scene has `left` and `right`, each its own clip with the props above (and `delay`, seconds before it starts), and
//   `ratio`: the left or top panel's share. frame-split.sh puts them side by side, or one above the other in a narrow frame.
//   screens  instead of a clip: a list of PNG paths (relative to video/), shown as a cross-fading slideshow of the
//            scene's length (opt-in; a scene without it is unchanged). `{platform}` in a path becomes the look's platform
//            (ios or android, from VIDEO_PLATFORM; default ios). The screens sit in a phone frame (`frame`: iphone,
//            android or none; default follows the platform). `hold` seconds per image (default 2.5).
// A framed scene is kept in raw/frames/<project>/ and used again while nothing that shapes it has changed: its props and length, the look,
// the recordings it uses and the framing code (RENDER_FORCE=1 frames everything again).
// Usage: node scripts/frames.mjs        Env: VIDEO_PROJECT, VIDEO_THEME, VIDEO_FORMAT
import {execFileSync} from 'node:child_process';
import {copyFileSync, existsSync, mkdirSync, readFileSync, utimesSync} from 'node:fs';
import {join} from 'node:path';
import {loadAdapter, resolveClip as resolveClip_} from './adapter.mjs';
import {frameKey, hashFileOnce, pruneFolders, readJson, sha, writeJson} from './cache.mjs';
import {applyCamera, resolveTargets, wantsCamera} from './camera.mjs';
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

/** Finds a scene's clip (the panel `label`, such as " left", for a split scene), or says which is missing. Looked up once per scene. */
const located = new Map();
function locate(id, label, spec) {
  const memo = `${id}|${label}|${spec.clip}`;
  if (located.has(memo)) return located.get(memo);
  const found = resolveClip(spec.clip);
  if (!found) throw new Error(`scene "${id}"${label}: no clip "${spec.clip}"${adapter ? ` in the ${adapter.name} adapter (record it, or add it to ${process.env.VIDEO_SOURCE ? '.kinhin/videos/' : ''}adapters/${adapter.name}/reference/)` : ' (the project has no adapter; give a path)'}`);
  located.set(memo, found);
  return found;
}

/**
 * One recording ready to be framed: resolves its target names and runs the camera and speed pass when its props ask for it (or
 * when `always` says the frame cannot do what the clip needs: a split panel starts and speeds nothing itself).
 * Returns {file, start, speed, covered}: `start` and `speed` are what is left for the frame to apply, `covered` that the laptop's
 * toolbar patch has been drawn already.
 */
function prepare(id, label, spec, found, length, {laptop = false, always = false} = {}) {
  let start = found.meta && existsSync(found.meta) ? JSON.parse(readFileSync(found.meta, 'utf8')).demoStartsAt ?? 0 : 0;
  let speed = spec.speed ?? 1;
  if (!(wantsCamera(spec) || (always && (start > 0 || speed !== 1)))) return {file: found.file, start, speed: String(speed), covered: false};
  // Only the laptop frame starts the clip late and changes its speed. The camera pass applies both, so what the frame gets
  // is a clip of exactly the scene's length (and, for the laptop, with the window's toolbar buttons already covered).
  const props = resolveTargets(spec, adapter?.manifest.clips?.[spec.clip]?.targets, `scene "${id}"${label}: clip "${spec.clip}"`);
  const out = join('out/.work', `${id}${label ? `-${label.replace(/\W/g, '')}` : ''}-camera.mp4`);
  const fromStory = laptop || always; // the laptop (and a split panel) play a clip from where its story starts, at its `speed`
  applyCamera({clip: found.file, out, props, start: fromStory ? start : 0, speed: fromStory && !Array.isArray(speed) ? Number(speed) : 1, length, cover: laptop ? env.BAR_COLOR : undefined});
  return {file: out, start: 0, speed: '1', covered: laptop};
}

/** Frames one clip scene into out/.work/<id>.mp4. */
function renderScene(scene, length) {
  if (scene.type === 'split') {
    const panels = ['left', 'right'].map((side) => {
      const spec = scene.props[side];
      const found = locate(scene.id, ` ${side}`, spec);
      const clip = prepare(scene.id, ` ${side}`, spec, found, length, {always: true});
      // A recorded app already has its own window; a terminal or a browser session gets a title bar.
      const frame = spec.frame ?? (found.kind === 'app' ? 'none' : 'window');
      return {file: clip.file, delay: spec.delay ?? 0, bar: frame === 'window' ? '1' : '0'};
    });
    const out = join('out/.work', `${scene.id}.mp4`);
    execFileSync('scripts/frame-split.sh', [panels[0].file, panels[1].file, out, String(length), panels[0].delay, panels[1].delay, panels[0].bar, panels[1].bar, String(scene.props.ratio ?? 0.5)].map(String), {env, stdio: 'inherit'});
    return;
  }
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
    return;
  }
  const out = join('out/.work', `${scene.id}.mp4`);
  // An app recording defaults to the laptop; a terminal or a browser session to a window.
  const found = locate(scene.id, '', scene.props);
  const frame = scene.props.frame ?? (found.kind === 'app' || (found.kind === 'path' && scene.type === 'device') ? 'macbook' : 'window');
  const clip = prepare(scene.id, '', scene.props, found, length, {laptop: frame === 'macbook'});
  if (frame === 'macbook') {
    execFileSync('scripts/frame-app.sh', [clip.file, out, String(clip.start), String(length)], {env: {...env, SPEED: clip.speed, ...(clip.covered && {COVER: '0'})}, stdio: 'inherit'});
  } else if (frame === 'window') {
    execFileSync('scripts/frame-terminal.sh', [clip.file, out, String(length)], {env, stdio: 'inherit'});
  } else {
    // No frame: the clip as it is, trimmed to the scene (assemble.mjs fits it to the format).
    execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-i', clip.file, '-t', String(length), '-an', '-c:v', 'libx264', '-crf', '17', out], {stdio: 'inherit'});
    console.log(`wrote ${out}`);
  }
}

/** The clip specs of a scene (the two panels of a split, or the scene's own props) and the slideshow images, as files on disk. */
function inputsOf(scene, length) {
  const specs = scene.type === 'split' ? [scene.props.left, scene.props.right] : Array.isArray(scene.props.screens) ? [] : [scene.props];
  const files = specs.map((spec, i) => {
    const found = locate(scene.id, scene.type === 'split' ? [' left', ' right'][i] : '', spec);
    return {file: hashFileOnce(found.file, hashes), meta: found.meta && existsSync(found.meta) ? readFileSync(found.meta, 'utf8') : null};
  });
  const images = (scene.props.screens ?? []).map((path) => path.replaceAll('{platform}', env.VIDEO_PLATFORM || 'ios'));
  for (const image of images) files.push({file: existsSync(image) ? hashFileOnce(image, hashes) : null});
  return {
    type: scene.type,
    props: scene.props,
    targets: specs.map((spec) => adapter?.manifest.clips?.[spec.clip]?.targets ?? null),
    length,
    look: shellEnv(p) + (env.VIDEO_PLATFORM ?? ''),
    files,
    code: codeHash,
  };
}

// The framing code, hashed once: a change to any of it frames every clip again.
const codeHash = sha(['frame-app.sh', 'frame-terminal.sh', 'frame-split.sh', 'frames.mjs', 'camera.mjs', 'speed.mjs', 'slideshow.mjs'].map((f) => readFileSync(join('scripts', f), 'utf8')));
const cacheDir = join('raw/frames', p.slug);
const cacheFile = join(cacheDir, '.cache.json');
const hashesFile = join(cacheDir, '.hashes.json');
const cache = readJson(cacheFile);
const hashes = readJson(hashesFile); // path, size and time of each recording, with its hash
pruneFolders('raw/frames'); // framed clips of projects and scenes that have not been built for two months

for (const scene of p.scenes.filter((s) => s.kind === 'clip')) {
  const length = timeline.scenes[scene.id].length;
  const out = join('out/.work', `${scene.id}.mp4`);
  const kept = join(cacheDir, `${scene.id}.mp4`);
  const key = frameKey(inputsOf(scene, length));
  if (!process.env.RENDER_FORCE && cache[scene.id] === key && existsSync(kept)) {
    copyFileSync(kept, out);
    utimesSync(kept, new Date(), new Date()); // used: keep it out of the prune
    console.log(`cached   ${out}`);
    continue;
  }
  renderScene(scene, length);
  mkdirSync(cacheDir, {recursive: true});
  copyFileSync(out, kept);
  cache[scene.id] = key;
  writeJson(cacheFile, cache);
}
// Written every build, so the folder's bookkeeping files count as used while its clips do.
mkdirSync(cacheDir, {recursive: true});
writeJson(cacheFile, cache);
writeJson(hashesFile, hashes);
