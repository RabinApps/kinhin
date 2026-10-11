// Prints a preset's clips as lines separated by the ASCII unit separator (0x1f: unlike a tab, bash `read` keeps empty fields) for the shell scripts: file, captions, make, hint, needs.
// Usage: node scripts/clips.mjs <preset name or path>
import { readFileSync, existsSync } from 'node:fs';

const arg = process.argv[2];
if (!arg) { console.error('usage: node scripts/clips.mjs <preset>'); process.exit(2); }
const path = existsSync(arg) ? arg : `presets/${arg}.json`;
if (!existsSync(path)) { console.error(`no preset "${arg}" (looked for ${path})`); process.exit(2); }

const preset = JSON.parse(readFileSync(path, 'utf8'));
if (!Array.isArray(preset.clips) || preset.clips.length === 0) {
  console.error(`${path}: "clips" must be a non-empty array`); process.exit(2);
}
for (const [i, clip] of preset.clips.entries()) {
  const fields = [clip.file, clip.captions, clip.make, clip.hint, clip.needs];
  if (typeof clip.file !== 'string' || clip.file === '') {
    console.error(`${path}: clip ${i} needs a "file"`); process.exit(2);
  }
  if (fields.some((f) => typeof f === 'string' && /[\x1f\n]/.test(f))) {
    console.error(`${path}: clip ${i} has a newline or control character in a field`); process.exit(2);
  }
  console.log([clip.file, clip.captions ?? '', clip.make ?? '', clip.hint ?? '', clip.needs ?? ''].join('\x1f'));
}
