#!/usr/bin/env node
// The one definition of "a good video": checks a finished build against its timeline and a set of budgets. The e2e
// tests and the CI `checks` job both use it, so they cannot disagree.
//
//   node scripts/verify.mjs out/<name>.mp4 [--timeline out/timeline.json] [--max-mb 10] [--max-seconds 90]
//                                          [--loudness -16] [--loudness-tolerance 3] [--no-audio]
// Exit 0 when every check passes; otherwise prints each failure and exits 1. As a library: verifyVideo(file, options).
//
// Checks: video stream with the timeline's frame size (when given); duration within 1 s of the timeline's total; an audio
// stream, with integrated loudness near the target; no black frames (any span of half a second or more); the
// caption file next to the video parses and has one entry per cue; the poster and hero GIF exist and are not blank;
// the file is within the size and duration budgets.
import {execFileSync, spawnSync} from 'node:child_process';
import {existsSync, readFileSync, statSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

const probe = (file, entries, select) =>
  JSON.parse(execFileSync('ffprobe', ['-v', 'error', ...(select ? ['-select_streams', select] : []), '-show_entries', entries, '-of', 'json', file]).toString());

/** Integrated loudness (LUFS) of a file's audio, or null when it has none. */
export function loudness(file) {
  const r = spawnSync('ffmpeg', ['-nostdin', '-hide_banner', '-i', file, '-vn', '-af', 'ebur128=framelog=quiet', '-f', 'null', '-'], {encoding: 'utf8'});
  const m = r.stderr.match(/Integrated loudness:\s*\n\s*I:\s*(-?[\d.]+) LUFS/);
  return m ? Number(m[1]) : null;
}

/** Spans of black longer than half a second, as [start, end] seconds. */
export function blackSpans(file) {
  const r = spawnSync('ffmpeg', ['-nostdin', '-hide_banner', '-i', file, '-an', '-vf', 'blackdetect=d=0.5:pic_th=0.98:pix_th=0.02', '-f', 'null', '-'], {encoding: 'utf8'});
  return [...r.stderr.matchAll(/black_start:([\d.]+) black_end:([\d.]+)/g)].map((m) => [Number(m[1]), Number(m[2])]);
}

/** True when an image is not (nearly) a single colour. */
export function notBlank(file) {
  // A GIF starts on a fade, so look a second in.
  const seek = file.endsWith('.gif') ? ['-ss', '1'] : [];
  const r = spawnSync('ffmpeg', ['-nostdin', '-v', 'error', ...seek, '-i', file, '-vf', 'scale=32:32,format=gray', '-frames:v', '1', '-f', 'rawvideo', 'pipe:1'], {maxBuffer: 1 << 20});
  const px = [...r.stdout];
  if (px.length < 100) return false;
  const mean = px.reduce((a, b) => a + b, 0) / px.length;
  const sd = Math.sqrt(px.reduce((a, b) => a + (b - mean) ** 2, 0) / px.length);
  return sd > 2;
}

export function parseSrt(text) {
  return text.trim() ? text.trim().split(/\n\s*\n/).map((block) => {
    const [n, time, ...lines] = block.split('\n');
    const m = time?.match(/^(\d\d):(\d\d):(\d\d),(\d{3}) --> (\d\d):(\d\d):(\d\d),(\d{3})$/);
    if (!m || !lines.length) throw new Error(`bad caption block: ${block.slice(0, 40)}`);
    const t = (a) => Number(a[0]) * 3600 + Number(a[1]) * 60 + Number(a[2]) + Number(a[3]) / 1000;
    return {n: Number(n), start: t(m.slice(1, 5)), end: t(m.slice(5, 9)), text: lines.join(' ')};
  }) : [];
}

export function verifyVideo(file, {timeline, maxMB, maxSeconds, loudnessTarget = -16, loudnessTolerance = 3, audio = true} = {}) {
  const failures = [];
  const fail = (msg) => failures.push(msg);
  if (!existsSync(file)) return {failures: [`${file} does not exist`], facts: {}};
  const base = file.replace(/\.mp4$/, '');
  const facts = {file, bytes: statSync(file).size};

  const v = probe(file, 'stream=width,height,codec_name', 'v:0').streams?.[0];
  if (!v) fail('no video stream');
  else {
    facts.width = v.width;
    facts.height = v.height;
    if (timeline?.format && (v.width !== timeline.format.width || v.height !== timeline.format.height)) fail(`frame is ${v.width}x${v.height}, expected ${timeline.format.width}x${timeline.format.height}`);
  }
  const duration = Number(probe(file, 'format=duration').format.duration);
  facts.seconds = Math.round(duration * 10) / 10;
  if (timeline && Math.abs(duration - timeline.total) > 1) fail(`duration ${duration.toFixed(1)} s is not within 1 s of the timeline's ${timeline.total} s`);
  if (maxSeconds && duration > maxSeconds) fail(`duration ${duration.toFixed(1)} s exceeds the ${maxSeconds} s budget`);
  if (maxMB && facts.bytes > maxMB * 1024 * 1024) fail(`size ${(facts.bytes / 1048576).toFixed(1)} MB exceeds the ${maxMB} MB budget`);

  if (audio) {
    const a = probe(file, 'stream=codec_name', 'a:0').streams?.[0];
    if (!a) fail('no audio stream');
    else {
      const lufs = loudness(file);
      facts.lufs = lufs;
      if (lufs === null) fail('could not measure loudness');
      else if (Math.abs(lufs - loudnessTarget) > loudnessTolerance) fail(`loudness ${lufs} LUFS is more than ${loudnessTolerance} LU from ${loudnessTarget}`);
    }
  }
  // Any half second of black is a bug (the fades at the ends are 0.25 s, through the backdrop, and never register).
  const black = blackSpans(file);
  if (black.length) fail(`black frames at ${black.map(([s, e]) => `${s.toFixed(1)}-${e.toFixed(1)} s`).join(', ')}`);

  const srt = `${base}.srt`;
  if (existsSync(srt)) {
    try {
      const entries = parseSrt(readFileSync(srt, 'utf8'));
      facts.captions = entries.length;
      const cues = timeline ? Object.values(timeline.scenes).reduce((n, s) => n + s.cues.length, 0) : null;
      if (cues !== null && entries.length !== cues) fail(`${entries.length} captions for ${cues} cues`);
      if (entries.some((c) => c.end <= c.start)) fail('a caption ends before it starts');
    } catch (e) {
      fail(`captions: ${e.message}`);
    }
  } else fail(`no caption file ${srt}`);
  for (const [suffix, what] of [['-poster.png', 'poster'], ['-hero.gif', 'hero GIF']]) {
    const f = `${base}${suffix}`;
    if (!existsSync(f)) fail(`no ${what} (${f})`);
    else if (!notBlank(f)) fail(`the ${what} is blank`);
  }
  return {failures, facts};
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const opt = (name) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
  const file = args.find((a) => !a.startsWith('--') && a !== opt('--timeline') && a !== opt('--max-mb') && a !== opt('--max-seconds') && a !== opt('--loudness') && a !== opt('--loudness-tolerance'));
  if (!file) {
    console.error('usage: node scripts/verify.mjs <video.mp4> [--timeline out/timeline.json] [--max-mb N] [--max-seconds N] [--no-audio]');
    process.exit(2);
  }
  const timelinePath = opt('--timeline');
  const {failures, facts} = verifyVideo(file, {
    timeline: timelinePath ? JSON.parse(readFileSync(timelinePath, 'utf8')) : undefined,
    maxMB: opt('--max-mb') && Number(opt('--max-mb')),
    maxSeconds: opt('--max-seconds') && Number(opt('--max-seconds')),
    loudnessTarget: opt('--loudness') ? Number(opt('--loudness')) : -16,
    loudnessTolerance: opt('--loudness-tolerance') ? Number(opt('--loudness-tolerance')) : 3,
    audio: !args.includes('--no-audio'),
  });
  console.log(JSON.stringify(facts));
  if (failures.length) {
    console.error(failures.map((f) => `  FAIL ${f}`).join('\n'));
    process.exit(1);
  }
  console.log('ok');
}
