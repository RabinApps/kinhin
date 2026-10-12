#!/usr/bin/env node
// Renders the narration of video/script/launch.json to one audio file per scene and writes out/voice-timings.json
// (seconds per scene) so scenes and captions can follow the voice. Three engines, all local and free:
//   say         macOS `say`. Zero setup; the default voices sound robotic unless you download a Premium voice.
//   kokoro      Kokoro-82M through the kokoro-js npm package (Apache-2.0 model; ~90 MB download on first use).
//   supertonic  Supertonic through its pip package (code MIT, model OpenRAIL-M; upstream archived Sep 2026, so
//               it works as installed but gets no fixes).
//
// Usage: node scripts/voice.mjs [--setup <engine>] [--audition] [--engine e] [--voice v] [script.json]
//   --setup kokoro|supertonic   install that engine's dependency (kokoro: npm i --no-save; supertonic: a venv)
//   --audition                  render one paragraph in several voices per engine into raw/voice-audition/
//   --engine, --voice           override the script's "voice" block (also VOICE_ENGINE, VOICE, RATE env)
import {execFileSync} from 'node:child_process';
import {mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const flag = (name) => {
  const i = args.indexOf(name);
  return i < 0 ? undefined : args.splice(i, 2)[1];
};
const has = (name) => {
  const i = args.indexOf(name);
  if (i >= 0) args.splice(i, 1);
  return i >= 0;
};
const setup = flag('--setup');
const audition = has('--audition');
const engineFlag = flag('--engine');
const voiceFlag = flag('--voice');
const scriptPath = resolve(args[0] ?? join(root, 'script/launch.json'));

const VOICES = {
  say: ['Samantha'], // add Premium voices by their `say -v '?'` name, e.g. "Ava (Premium)"
  kokoro: ['af_heart', 'af_bella', 'af_nicole', 'am_michael', 'am_fenrir', 'bf_emma', 'bm_george'],
  supertonic: ['F3', 'F4', 'F5', 'M3', 'M4', 'M5'],
};
const venvPython = join(root, '.venv-tts/bin/python');
const sh = (cmd, cmdArgs, opts = {}) => execFileSync(cmd, cmdArgs, {stdio: 'inherit', ...opts});
const seconds = (file) =>
  Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file]).toString().trim());
const toM4a = (wav, m4a) => execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', wav, '-c:a', 'aac', '-b:a', '192k', m4a]);

if (setup) {
  if (setup === 'kokoro') sh('npm', ['i', '--no-save', 'kokoro-js'], {cwd: root});
  else if (setup === 'supertonic') {
    sh('python3', ['-m', 'venv', join(root, '.venv-tts')]);
    sh(venvPython, ['-m', 'pip', 'install', '-q', 'supertonic']);
  } else throw new Error(`--setup takes kokoro or supertonic, not "${setup}"`);
  process.exit(0);
}

const script = JSON.parse(readFileSync(scriptPath, 'utf8'));
const engine = engineFlag || process.env.VOICE_ENGINE || script.voice?.engine || 'say';
const voice = voiceFlag || process.env.VOICE || script.voice?.name || VOICES[engine]?.[0];
const rate = process.env.RATE || script.voice?.rate || 175; // `say` words per minute
const speed = Number(process.env.SPEED || script.voice?.speed || 1); // kokoro/supertonic speed factor
if (!(engine in VOICES)) throw new Error(`unknown engine "${engine}" (say, kokoro, supertonic)`);

// Respell names so the engines pronounce them; the captions keep the original spelling.
const speakable = (text) =>
  Object.entries(script.pronounce ?? {}).reduce((t, [from, to]) => t.replaceAll(from, to), text);

let kokoro; // loaded once
async function render(eng, voiceName, jobs) {
  // jobs: [{text, out}] where out is a .m4a path; returns the durations in seconds.
  const durations = [];
  if (eng === 'say') {
    for (const job of jobs) {
      const aiff = job.out.replace(/\.m4a$/, '.aiff');
      execFileSync('say', ['-v', voiceName, '-r', String(rate), '-o', aiff, speakable(job.text)]);
      toM4a(aiff, job.out);
      rmSync(aiff);
      durations.push(seconds(job.out));
    }
  } else if (eng === 'kokoro') {
    if (!kokoro) {
      const {KokoroTTS} = await import(join(root, 'node_modules/kokoro-js/dist/kokoro.js')).catch(() => {
        throw new Error('kokoro-js is not installed: node scripts/voice.mjs --setup kokoro');
      });
      kokoro = await KokoroTTS.from_pretrained('onnx-community/Kokoro-82M-v1.0-ONNX', {dtype: 'q8', device: 'cpu'});
    }
    for (const job of jobs) {
      const wav = job.out.replace(/\.m4a$/, '.wav');
      const audio = await kokoro.generate(speakable(job.text), {voice: voiceName, speed});
      await audio.save(wav);
      toM4a(wav, job.out);
      rmSync(wav);
      durations.push(seconds(job.out));
    }
  } else {
    const list = jobs.map((job) => ({text: speakable(job.text), voice: voiceName, out: job.out.replace(/\.m4a$/, '.wav'), speed}));
    const jobsFile = join(dirname(jobs[0].out), '.supertonic-jobs.json');
    writeFileSync(jobsFile, JSON.stringify(list));
    execFileSync(venvPython, [join(root, 'scripts/tts_supertonic.py'), jobsFile], {stdio: ['ignore', 'ignore', 'inherit']});
    rmSync(jobsFile);
    for (const [i, job] of jobs.entries()) {
      toM4a(list[i].out, job.out);
      rmSync(list[i].out);
      durations.push(seconds(job.out));
    }
  }
  return durations;
}

mkdirSync(join(root, 'out'), {recursive: true});

if (audition) {
  const dir = join(root, 'raw/voice-audition');
  rmSync(dir, {recursive: true, force: true});
  mkdirSync(dir, {recursive: true});
  const sample = script.scenes.find((s) => s.id === 'solution')?.narration ?? script.scenes[0].narration;
  for (const eng of Object.keys(VOICES)) {
    for (const v of VOICES[eng]) {
      try {
        const out = join(dir, `${eng}-${v.replace(/\W+/g, '_')}.m4a`);
        const [d] = await render(eng, v, [{text: sample, out}]);
        console.log(`${eng.padEnd(11)} ${v.padEnd(10)} ${d.toFixed(1)}s`);
      } catch (e) {
        console.log(`${eng.padEnd(11)} ${v.padEnd(10)} skipped: ${String(e.message).split('\n')[0]}`);
      }
    }
  }
  console.log(`\nListen: open ${dir}   (then: node scripts/voice.mjs --engine <e> --voice <v>)`);
  process.exit(0);
}

const outDir = join(root, 'raw/voice');
rmSync(outDir, {recursive: true, force: true});
mkdirSync(outDir, {recursive: true});

// A scene's narration is a list of cues. `cues` gives each cue's start (seconds into the scene); `narration` is
// split into sentences that play one after another, `lead` seconds in, `gap` apart.
const sentences = (text) => text.match(/[^.!?]+[.!?]+/g)?.map((t) => t.trim()) ?? [text];
const jobs = [];
const plan = script.scenes.map((scene) => {
  const cues = scene.cues ?? sentences(scene.narration).map((text) => ({text}));
  return {scene, cues: cues.map((cue, i) => {
    const job = {text: cue.say ?? cue.text, out: join(outDir, `${scene.id}-${i + 1}.m4a`)};
    jobs.push(job);
    return {...cue, job};
  })};
});
const durations = await render(engine, voice, jobs);
jobs.forEach((job, i) => (job.seconds = durations[i]));

const lead = (scene) => scene.lead ?? script.lead ?? 0.5;
const timings = {engine, voice, scenes: {}};
for (const {scene, cues} of plan) {
  let cursor = lead(scene);
  const placed = cues.map((cue) => {
    const start = cue.at ?? cursor;
    const end = start + cue.job.seconds;
    cursor = end + (script.gap ?? 0.35);
    return {text: cue.text, file: cue.job.out.replace(root + '/', ''), start: round(start), end: round(end)};
  });
  const speechEnd = placed.at(-1).end;
  timings.scenes[scene.id] = {speechEnd: round(speechEnd), cues: placed};
  console.log(`${scene.id.padEnd(9)} speech ends ${speechEnd.toFixed(1)}s  (${placed.length} cues)`);
}
writeFileSync(join(root, 'out/voice-timings.json'), JSON.stringify(timings, null, 2) + '\n');
function round(x) {
  return Math.round(x * 100) / 100;
}
process.exit(0); // kokoro's phonemizer (wasm) raises an unhandled error on shutdown
