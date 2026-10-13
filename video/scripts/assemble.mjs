#!/usr/bin/env node
// Builds the voice-over cut on the clock in out/.work/timeline.json (scripts/voice.mjs, then scripts/retime.mjs).
// Every scene is one clip, in the project's order: canvas scenes come from raw/scenes/<project>/<id>.mp4
// (render-titles.mjs), device and terminal scenes from out/.work/<id>.mp4 (frames.mjs). Each is made exactly as long as
// the scene needs (a short clip holds its last frame) and fades in and out through the theme's backdrop; the
// narration is placed cue by cue, music (out/.work/music.json) ducks under the voice, and captions are burned in.
//   out/.work/music.json                     optional (written by fetch-music.mjs)
// Outputs, in out/<name>/ (one folder per video; out/.work is scratch): <name>.mp4, .webm, -poster.png, -hero.gif, <name>.srt (every caption, for a player) and music-credit.txt
// Captions follow the project's `captions` block (burn on or off, which scenes, a style); out/<name>/<name>.srt has every cue for a player either way.
// Usage: node scripts/assemble.mjs      Env: VIDEO_CAPTIONS=on|off|all, VIDEO_CAPTION_STYLE, the music settings from out/.work/music.json (see fetch-music.mjs),
//        VIDEO_FAST=1 (a preview: quicker encode, no WebM)
import {execFileSync, spawnSync} from 'node:child_process';
import {copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {assColor} from '../shared/resolve.mjs';
import {loadProject, root} from './project.mjs';
import {edgeFraction} from './verify.mjs';

process.chdir(root);
const tl = JSON.parse(readFileSync('out/.work/timeline.json', 'utf8'));
const S = tl.scenes;
const look = loadProject();
const {format, theme, outName} = look;
const ff = (args) => execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', ...args], {stdio: 'inherit'});
const FADE = 0.25;
const FAST = !!process.env.VIDEO_FAST;

// 1. One normalised clip per scene (format-sized, 30 fps), cut or held to the scene's length, faded at both ends.
const mix = (a, b) => '0x' + [1, 3, 5].map((i) => Math.round((parseInt(a.slice(i, i + 2), 16) + parseInt(b.slice(i, i + 2), 16)) / 2).toString(16).padStart(2, '0')).join('');
const bg = mix(theme.background.from, theme.background.to); // the middle of the backdrop, for fades and padding
const parts = Object.entries(S).map(([id, s], i) => {
  const file = s.kind === 'canvas' ? `raw/scenes/${tl.project}/${id}.mp4` : `out/.work/${id}.mp4`;
  if (!existsSync(file)) throw new Error(`missing ${file}`);
  const vf = [
    `scale=${format.width}:${format.height}:force_original_aspect_ratio=decrease`,
    `pad=${format.width}:${format.height}:(ow-iw)/2:(oh-ih)/2:${bg}`,
    'fps=30', 'tpad=stop_mode=clone:stop_duration=30', 'format=yuv420p',
  ].join(',');
  const out = `out/.work/part-${i + 1}.mp4`;
  ff(['-i', file, '-vf', `${vf},trim=duration=${s.length},setpts=PTS-STARTPTS,fade=t=in:st=0:d=${FADE}:color=${bg},fade=t=out:st=${Math.max(0, s.length - FADE)}:d=${FADE}:color=${bg}`,
    '-an', '-c:v', 'libx264', '-crf', '17', out]);
  return {id, out, length: s.length};
});
const total = parts.reduce((a, p) => a + p.length, 0);
const list = parts.map((p) => `file '${p.out.replace('out/.work/', '')}'`).join('\n');
writeFileSync('out/.work/parts.txt', list);
ff(['-f', 'concat', '-safe', '0', '-i', 'out/.work/parts.txt', '-c', 'copy', 'out/.work/picture.mp4']);

// 2. The voice: every cue at its place on the final clock, levelled to -16 LUFS.
const cues = Object.values(S).flatMap((s) => s.cues.map((c) => ({file: c.file, at: s.start + c.start})));
const inputs = cues.flatMap((c) => ['-i', c.file]);
let graph = cues.map((c, i) => `[${i}:a]adelay=${Math.round(c.at * 1000)}|${Math.round(c.at * 1000)}[v${i}]`).join(';');
graph += `;${cues.map((_, i) => `[v${i}]`).join('')}amix=inputs=${cues.length}:normalize=0,loudnorm=I=-16:TP=-1.5:LRA=11,apad=whole_dur=${total}[voice]`;
ff([...inputs, '-filter_complex', graph, '-map', '[voice]', '-t', String(total), '-ar', '48000', 'out/.work/voice.wav']);

// 3. Optional music under the voice: fade in, duck while the narrator speaks, fade out.
const mcfg = existsSync('out/.work/music.json') ? JSON.parse(readFileSync('out/.work/music.json', 'utf8')) : {enabled: false};
const music = mcfg.enabled && mcfg.file ? mcfg.file : null;
let audio = 'out/.work/voice.wav';
if (music) {
  const fadeOut = Math.min(mcfg.fadeOut, total);
  const shaped = `atrim=0:${total},asetpts=N/SR/TB,volume=${mcfg.volume},afade=t=in:d=${mcfg.fadeIn}` + (fadeOut ? `,afade=t=out:st=${Math.max(0, total - fadeOut)}:d=${fadeOut}` : '');
  const mix = mcfg.duck
    ? `[0:a]asplit[vs][vm];[m][vs]sidechaincompress=threshold=0.02:ratio=8:attack=30:release=500[duck];[vm][duck]amix=inputs=2:normalize=0[mix]`
    : `[0:a][m]amix=inputs=2:normalize=0[mix]`;
  ff([
    '-i', 'out/.work/voice.wav', ...(mcfg.loop ? ['-stream_loop', '-1'] : []), ...(mcfg.start ? ['-ss', String(mcfg.start)] : []), '-i', music, '-filter_complex',
    `[1:a]${shaped}[m];${mix}`,
    '-map', '[mix]', '-t', String(total), '-ar', '48000', 'out/.work/audio.wav',
  ]);
  audio = 'out/.work/audio.wav';
}

// The voice was levelled on its own; music added afterwards moves the total, so level the finished mix to -16 LUFS,
// measured first and then applied exactly (two passes).
{
  const target = 'I=-16:TP=-1.5:LRA=11';
  const measured = spawnSync('ffmpeg', ['-nostdin', '-hide_banner', '-i', audio, '-af', `loudnorm=${target}:print_format=json`, '-f', 'null', '-'], {encoding: 'utf8'});
  const json = measured.stderr.slice(measured.stderr.lastIndexOf('{'));
  try {
    const m = JSON.parse(json);
    ff(['-i', audio, '-af', `loudnorm=${target}:measured_I=${m.input_i}:measured_TP=${m.input_tp}:measured_LRA=${m.input_lra}:measured_thresh=${m.input_thresh}:offset=${m.target_offset}:linear=true`, '-ar', '48000', 'out/.work/final.wav']);
    audio = 'out/.work/final.wav';
  } catch {
    console.warn('could not measure the mix; keeping it as it is');
  }
}

// 4. Captions (the project's `captions` block, see shared/resolve.mjs): burned in unless turned off, in the chosen style;
// out/<name>/<name>.srt always has every cue for a player. Picture and sound are joined here.
const cap = look.captions;
const narrowFrame = format.width / format.height < 1.2;
// libass measures sizes, outlines, shadows and margins in units of a 288-line frame, whatever the real size, so pixel
// values are divided by `unit` (found by measuring: Fontsize 100 on a 1350-line frame is 469 px).
// Landscape: small captions at the bottom. Portrait and square: bigger (sized by width); on device scenes just under
// the laptop (it sits at 36% of the height), on terminal scenes at the bottom, under the window.
const unit = format.height / 288;
const laptopBottom = 0.36 * format.height + ((825 + 32 + 28) / 2) * look.fit;
const styleFor = (type) => {
  const fontPx = (narrowFrame ? theme.caption.size * (format.width / 288) * 1.15 : theme.caption.size * unit) * cap.scale;
  const outlinePx = (narrowFrame ? 3.5 * (format.width / 1080) : 2 * unit) * Math.max(1, cap.scale * 0.9);
  const autoMargin = narrowFrame ? (type === 'device' ? laptopBottom + 0.04 * format.height : 0.05 * format.height) : 24 * unit;
  const bottomMargin = narrowFrame ? 0.05 * format.height : 24 * unit;
  // Position: auto keeps captions clear of the product; the others are fixed.
  const [align, marginPx] =
    cap.position === 'top' ? [6, bottomMargin]
    : cap.position === 'middle' ? [10, 0]
    : cap.position === 'bottom' ? [2, bottomMargin]
    : narrowFrame && type === 'device' ? [6, autoMargin]
    : [2, autoMargin];
  const border =
    cap.border === 'box' ? `BorderStyle=3,BackColour=${assColor(cap.box)},Outline=${((outlinePx * 2) / unit).toFixed(2)}`
    // The shadow is the theme's contrasting colour at 60%, tight to the text: a glow on light themes, a shade on dark ones.
    : cap.border === 'shadow' ? `BorderStyle=1,Outline=0,BackColour=${assColor(`${cap.outline.slice(0, 7)}99`)},Shadow=${((outlinePx * 0.8) / unit).toFixed(2)}`
    : cap.border === 'none' ? 'BorderStyle=1,Outline=0,Shadow=0'
    : `BorderStyle=1,Outline=${(outlinePx / unit).toFixed(2)},Shadow=0`;
  return [
    `Fontname=${cap.font}`, `Fontsize=${(fontPx / unit).toFixed(2)}`, `Bold=${cap.bold ? -1 : 0}`,
    `PrimaryColour=${assColor(cap.text)}`, `OutlineColour=${assColor(cap.outline)}`, border, `Alignment=${align}`, `MarginV=${(marginPx / unit).toFixed(1)}`,
  ].join(',');
};
// Which scenes get burned captions: the clip scenes (no text of their own) by default, all of them, or a list of ids.
const burned = cap.scenes === 'all' ? Object.keys(S) : cap.scenes === 'clips' ? Object.entries(S).filter(([, s]) => s.kind === 'clip').map(([id]) => id) : cap.scenes;
const stamp = (x) => {
  const ms = Math.round(x * 1000);
  const p = (n, w = 2) => String(n).padStart(w, '0');
  return `${p(Math.floor(ms / 3600000))}:${p(Math.floor(ms / 60000) % 60)}:${p(Math.floor(ms / 1000) % 60)},${p(ms % 1000, 3)}`;
};
const limit = format.width >= 1500 ? 44 : 24;
const wrap = (t) => {
  if (t.length <= limit) return t;
  const w = t.split(' ');
  let best = 1;
  let gap = Infinity;
  for (let i = 1; i < w.length; i++) {
    const g = Math.abs(w.slice(0, i).join(' ').length - t.length / 2) - (w[i - 1].endsWith(',') ? 6 : 0);
    if (g < gap) [best, gap] = [i, g];
  }
  return `${w.slice(0, best).join(' ')}\n${w.slice(best).join(' ')}`;
};
const cuesOf = (types) => Object.entries(S).filter(([id, s]) => burned.includes(id) && types.includes(s.type)).flatMap(([, s]) => s.cues.map((c) => ({...c, start: s.start + c.start, end: s.start + c.end})));
const groups = [['device'], ['terminal'], ['title', 'statement', 'queue', 'parallel', 'map', 'outro']].map((types) => ({type: types[0], cues: cuesOf(types)})).filter((g) => g.cues.length);
const filters = groups.map((g, i) => {
  writeFileSync(`out/.work/burned-${i}.srt`, g.cues.map((c, n) => `${n + 1}\n${stamp(c.start)} --> ${stamp(c.end)}\n${wrap(c.text)}\n`).join('\n'));
  return `subtitles=out/.work/burned-${i}.srt:force_style='${styleFor(g.type)}'`;
});
const vf = !cap.burn || !filters.length ? 'null' : filters.join(',');
const dir = `out/${outName}`; // everything a build delivers lives in its own folder; out/.work is scratch
mkdirSync(dir, {recursive: true});
const video = `${dir}/${outName}.mp4`;
ff(['-i', 'out/.work/picture.mp4', '-i', audio, '-vf', vf, '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-crf', FAST ? '28' : '18', '-preset', FAST ? 'veryfast' : 'medium', '-pix_fmt', 'yuv420p',
  '-c:a', 'aac', '-b:a', '192k', '-shortest', '-movflags', '+faststart', video]);
if (!FAST) ff(['-i', video, '-c:v', 'libvpx-vp9', '-crf', '33', '-b:v', '0', '-c:a', 'libopus', `${dir}/${outName}.webm`]);
// The poster and the hero GIF come from the most detailed scene: a frame near the end of each scene is scored by how
// much of it is edges (text, shapes, the product), and the best one wins; a clip scene (the product on screen) is
// preferred when it scores about as well.
const candidates = Object.entries(S).map(([id, s], i) => {
  const at = s.start + Math.min(s.length * 0.8, s.length - 0.6);
  const f = `out/.work/.poster-${i}.png`;
  ff(['-ss', String(at), '-i', video, '-frames:v', '1', f]);
  return {id, scene: s, at, file: f, score: edgeFraction(f) * (s.kind === 'clip' ? 1.5 : 1)};
});
const best = candidates.reduce((a, b) => (b.score > a.score ? b : a));
ff(['-i', best.file, '-vf', `scale=${Math.min(1200, format.width)}:-2`, `${dir}/${outName}-poster.png`]);
ff(['-ss', String(best.scene.start), '-t', '10', '-i', video, '-vf', 'fps=10,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse', `${dir}/${outName}-hero.gif`]);
for (const c of candidates) rmSync(c.file, {force: true});
if (existsSync('out/.work/music-credit.txt')) copyFileSync('out/.work/music-credit.txt', `${dir}/music-credit.txt`);
writeFileSync(`${dir}/${outName}.srt`, readFileSync(`out/.work/${tl.project}.captions.srt`));
for (const f of [...parts.map((p) => p.out), 'out/.work/parts.txt', ...groups.map((_, i) => `out/.work/burned-${i}.srt`), 'out/.work/picture.mp4', 'out/.work/voice.wav', 'out/.work/audio.wav', 'out/.work/final.wav']) rmSync(f, {force: true});
console.log(`wrote ${video} (${format.name} ${format.width}x${format.height}, ${theme.name}, ${total.toFixed(1)}s${music ? ', with music' : ', no music'}), .webm, -poster.png, -hero.gif, .srt`);
