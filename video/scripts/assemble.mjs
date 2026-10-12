#!/usr/bin/env node
// Builds the voice-over cut from the clips in raw/ and out/, on the clock in out/timeline.json
// (scripts/voice.mjs, then scripts/retime.mjs). Each part is made exactly as long as its scenes need (a short
// clip holds its last frame), the narration is placed cue by cue, music (raw/music.*) ducks under the voice,
// and launch.srt is burned in.
//
//   raw/opening.mp4        Motion Canvas "opening" render: intro + problem + solution
//   out/app-framed.mp4     scripts/frame-app.sh
//   out/install-framed.mp4 scripts/frame-terminal.sh (from raw/install.mp4 or reference/install.mp4)
//   raw/closing.mp4        Motion Canvas "closing" render: lanes + outro
//   raw/music.{mp3,m4a,wav,flac,ogg}   optional
// Outputs (out/): launch.mp4, launch.webm, poster.png, hero.gif
// Captions are burned in only for the scenes without text of their own (CAPTION_SCENES, default app,install);
// the title scenes already show their words. captions/launch.srt has every cue for the site player.
// Usage: node scripts/assemble.mjs      Env: NO_CAPTIONS=1, CAPTION_SCENES, MUSIC_VOLUME (default 0.35, before ducking)
import {execFileSync} from 'node:child_process';
import {existsSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
process.chdir(root);
const tl = JSON.parse(readFileSync('out/timeline.json', 'utf8'));
const S = tl.scenes;
const ff = (args) => execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', ...args], {stdio: 'inherit'});

// 1. The four video parts, each normalised to 1080p30 and cut or held to the length its scenes add up to.
const parts = [
  {file: 'raw/opening.mp4', length: S.intro.length + S.problem.length + S.solution.length},
  {file: 'out/app-framed.mp4', length: S.app.length},
  {file: 'out/install-framed.mp4', length: S.install.length},
  {file: 'raw/closing.mp4', length: S.lanes.length + S.outro.length},
];
for (const [i, p] of parts.entries()) {
  if (!existsSync(p.file)) throw new Error(`missing ${p.file}`);
  p.out = `out/part-${i + 1}.mp4`;
  const vf = 'scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:white,fps=30,tpad=stop_mode=clone:stop_duration=30,format=yuv420p';
  ff(['-i', p.file, '-vf', vf, '-t', String(p.length), '-an', '-c:v', 'libx264', '-crf', '17', p.out]);
}
const total = parts.reduce((a, p) => a + p.length, 0);
const list = parts.map((p) => `file '${p.out.replace('out/', '')}'`).join('\n');
execFileSync('node', ['-e', `require('fs').writeFileSync('out/parts.txt', ${JSON.stringify(list)})`]);
ff(['-f', 'concat', '-safe', '0', '-i', 'out/parts.txt', '-c', 'copy', 'out/picture.mp4']);

// 2. The voice: every cue at its place on the final clock, levelled to -16 LUFS.
const cues = Object.values(S).flatMap((s) => s.cues.map((c) => ({file: c.file, at: s.start + c.start})));
const inputs = cues.flatMap((c) => ['-i', c.file]);
let graph = cues.map((c, i) => `[${i}:a]adelay=${Math.round(c.at * 1000)}|${Math.round(c.at * 1000)}[v${i}]`).join(';');
graph += `;${cues.map((_, i) => `[v${i}]`).join('')}amix=inputs=${cues.length}:normalize=0,loudnorm=I=-16:TP=-1.5:LRA=11,apad=whole_dur=${total}[voice]`;
ff([...inputs, '-filter_complex', graph, '-map', '[voice]', '-t', String(total), '-ar', '48000', 'out/voice.wav']);

// 3. Optional music under the voice: fade in, duck while the narrator speaks, fade out.
const music = ['mp3', 'm4a', 'wav', 'flac', 'ogg'].map((e) => `raw/music.${e}`).find(existsSync);
let audio = 'out/voice.wav';
if (music) {
  const vol = process.env.MUSIC_VOLUME ?? '0.35';
  ff([
    '-i', 'out/voice.wav', '-stream_loop', '-1', '-i', music, '-filter_complex',
    `[1:a]atrim=0:${total},volume=${vol},afade=t=in:d=2,afade=t=out:st=${total - 3}:d=3[m];` +
      `[0:a]asplit[vs][vm];[m][vs]sidechaincompress=threshold=0.02:ratio=8:attack=30:release=500[duck];` +
      `[vm][duck]amix=inputs=2:normalize=0[mix]`,
    '-map', '[mix]', '-t', String(total), '-ar', '48000', 'out/audio.wav',
  ]);
  audio = 'out/audio.wav';
}

// 4. Captions burned in, picture and sound joined.
const style = 'Fontname=Helvetica,Fontsize=11,PrimaryColour=&H000000&,OutlineColour=&HFFFFFF&,BorderStyle=1,Outline=2,Shadow=0,Alignment=2,MarginV=24';
const burned = (process.env.CAPTION_SCENES ?? 'app,install').split(',');
const stamp = (x) => {
  const ms = Math.round(x * 1000);
  const p = (n, w = 2) => String(n).padStart(w, '0');
  return `${p(Math.floor(ms / 3600000))}:${p(Math.floor(ms / 60000) % 60)}:${p(Math.floor(ms / 1000) % 60)},${p(ms % 1000, 3)}`;
};
const wrap = (t) => {
  if (t.length <= 44) return t;
  const w = t.split(' ');
  let best = 1;
  let gap = Infinity;
  for (let i = 1; i < w.length; i++) {
    const g = Math.abs(w.slice(0, i).join(' ').length - t.length / 2) - (w[i - 1].endsWith(',') ? 6 : 0);
    if (g < gap) [best, gap] = [i, g];
  }
  return `${w.slice(0, best).join(' ')}\n${w.slice(best).join(' ')}`;
};
const subset = Object.entries(S).filter(([id]) => burned.includes(id)).flatMap(([, s]) => s.cues.map((c) => ({...c, start: s.start + c.start, end: s.start + c.end})));
writeFileSync('out/burned.srt', subset.map((c, i) => `${i + 1}\n${stamp(c.start)} --> ${stamp(c.end)}\n${wrap(c.text)}\n`).join('\n'));
const vf = process.env.NO_CAPTIONS || !subset.length ? 'null' : `subtitles=out/burned.srt:force_style='${style}'`;
ff(['-i', 'out/picture.mp4', '-i', audio, '-vf', vf, '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-crf', '18', '-pix_fmt', 'yuv420p',
  '-c:a', 'aac', '-b:a', '192k', '-shortest', '-movflags', '+faststart', 'out/launch.mp4']);
ff(['-i', 'out/launch.mp4', '-c:v', 'libvpx-vp9', '-crf', '33', '-b:v', '0', '-c:a', 'libopus', 'out/launch.webm']);
ff(['-ss', String(S.app.start + 8), '-i', 'out/launch.mp4', '-frames:v', '1', '-vf', 'scale=1200:630:force_original_aspect_ratio=increase,crop=1200:630', 'out/poster.png']);
ff(['-ss', String(S.app.start), '-t', '10', '-i', 'out/launch.mp4', '-vf', 'fps=10,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse', 'out/hero.gif']);
for (const f of ['out/part-1.mp4', 'out/part-2.mp4', 'out/part-3.mp4', 'out/part-4.mp4', 'out/parts.txt', 'out/burned.srt', 'out/picture.mp4', 'out/voice.wav', 'out/audio.wav']) rmSync(f, {force: true});
console.log(`wrote out/launch.mp4 (${total.toFixed(1)}s${music ? ', with music' : ', no music'}), launch.webm, poster.png, hero.gif`);
