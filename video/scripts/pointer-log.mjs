#!/usr/bin/env node
// A pointer log (`kinhin video record --pointer`: where the pointer was over a window and where it clicked) cut to a clip's story,
// for the committed reference clips: its times count from the story's start, and only the readings in the story's first `keep`
// seconds are kept. make-reference.sh calls this with: node scripts/pointer-log.mjs IN OUT START KEEP
import {readFileSync, writeFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

/** The log cut to a story that starts `start` seconds in and runs `keep` seconds: times counted from the start, rounded to milliseconds. */
export function cutPointerLog(log, start, keep) {
  const inStory = (r) => r.t >= start && r.t - start <= keep;
  const shift = (r) => ({...r, t: Math.round((r.t - start) * 1000) / 1000});
  return {samples: log.samples.filter(inStory).map(shift), clicks: log.clicks.filter(inStory).map(shift)};
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [input, output, start, keep] = process.argv.slice(2);
  if (!input || !output || !Number.isFinite(Number(start)) || !Number.isFinite(Number(keep))) {
    console.error('usage: node scripts/pointer-log.mjs IN OUT START KEEP');
    process.exit(2);
  }
  const cut = cutPointerLog(JSON.parse(readFileSync(input, 'utf8')), Number(start), Number(keep));
  writeFileSync(output, JSON.stringify(cut, null, 2));
}
