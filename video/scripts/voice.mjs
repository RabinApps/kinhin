#!/usr/bin/env node
// Renders the narration of video/script/launch.json to one audio file per scene with macOS `say`, and writes
// out/voice-timings.json (seconds per scene) so scenes and captions can follow the voice.
// Usage: node scripts/voice.mjs [script.json]     Env: VOICE (name) and RATE (words/min) override the script.
// Voices: `say -v '?'`. Premium voices (System Settings > Accessibility > Spoken Content > Manage Voices) sound
// far better than the default ones; name them exactly as `say -v '?'` lists them, e.g. "Ava (Premium)".
import {execFileSync} from 'node:child_process';
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const scriptPath = resolve(process.argv[2] ?? join(root, 'script/launch.json'));
const script = JSON.parse(readFileSync(scriptPath, 'utf8'));
const voice = process.env.VOICE ?? script.voice?.name ?? 'Samantha';
const rate = process.env.RATE ?? script.voice?.rate ?? 175;
const outDir = join(root, 'raw/voice');
mkdirSync(outDir, {recursive: true});
mkdirSync(join(root, 'out'), {recursive: true});

// Respell names so `say` pronounces them; the captions keep the original spelling.
const speakable = (text) =>
  Object.entries(script.pronounce ?? {}).reduce((t, [from, to]) => t.replaceAll(from, to), text);

const timings = {voice, rate: Number(rate), scenes: {}};
for (const scene of script.scenes) {
  const aiff = join(outDir, `${scene.id}.aiff`);
  const m4a = join(outDir, `${scene.id}.m4a`);
  execFileSync('say', ['-v', voice, '-r', String(rate), '-o', aiff, speakable(scene.narration)]);
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', aiff, '-c:a', 'aac', '-b:a', '192k', m4a]);
  const seconds = Number(
    execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', m4a])
      .toString()
      .trim(),
  );
  timings.scenes[scene.id] = Math.round(seconds * 100) / 100;
  console.log(`${scene.id.padEnd(9)} ${seconds.toFixed(1)}s  ${scene.narration.length} chars`);
}
const total = Object.values(timings.scenes).reduce((a, b) => a + b, 0);
console.log(`total     ${total.toFixed(1)}s  (voice: ${voice}, ${rate} wpm)`);
writeFileSync(join(root, 'out/voice-timings.json'), JSON.stringify(timings, null, 2) + '\n');
