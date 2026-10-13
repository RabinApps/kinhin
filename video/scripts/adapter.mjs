// Adapters keep everything product-specific out of the pipeline. An adapter is a directory, video/adapters/<name>/,
// with an adapter.json and the recorders that make a product's clips:
//
//   adapter.json   { "name", "description", "clips": { <clip name>: {...} }, "needs": [ {tool, why, how, optional} ] }
//     "kind": "app"       a screen recording of the product. "record": a script (relative to the adapter) that
//                         writes $VIDEO_RAW_DIR/<clip>.mov and <clip>.json ({"demoStartsAt": seconds into the file
//                         at which the story begins}); "recordInVm": optional, the same in a throwaway VM.
//     "kind": "browser"   a scripted browser session of a web product, recorded by scripts/record-web.sh into
//                         <clip>.webm. "scenario": a scenario JSON (relative to the adapter); "serve": a command that
//                         starts the product (run from the repository root, inside the runner); "waitUrl": where to
//                         wait for it; "runner": local (default), docker or apple.
//     "kind": "terminal"  a VHS tape ("tape") recorded by scripts/record-terminal.sh in four variants (light or dark,
//                         landscape or portrait); "hideFromLine": the output line to mask from, when the tail of the
//                         output should not show (an optional nicety).
//   reference/     small committed clips (<clip>.mp4 and <clip>.json, install-dark-portrait.mp4, ...) so the video
//                  builds without recording anything; scripts/make-reference.sh makes them from raw/<adapter>/.
//
// A project file names its adapter ("adapter": "kinhin"); a scene's `props.clip` is a clip of that adapter.
// Your own recordings in video/raw/<adapter>/ win over the committed reference clips.
// scripts/record-clip.mjs records any clip of an adapter, whatever its kind.
// CLI: node scripts/adapter.mjs <name> [--clip <clip>] --env     shell variables for the recorder scripts
import {existsSync, readFileSync, readdirSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {adapterFile, readConfig, root, videosDir} from './project.mjs';

export function listAdapters() {
  const names = (dir) => (existsSync(dir) ? readdirSync(dir).filter((n) => adapterFile(n) && existsSync(join(dir, n))) : []);
  return [...new Set([...(videosDir() ? names(join(videosDir(), 'adapters')) : []), ...names(join(root, 'adapters'))])];
}

export function loadAdapter(name) {
  const file = adapterFile(name);
  if (!file) throw new Error(`no adapter "${name}" (video/adapters/${name}/adapter.json${videosDir() ? ` or ${videosDir()}/adapters/${name}/adapter.yml` : ''}; available: ${listAdapters().join(', ') || 'none'})`);
  const dir = dirname(file);
  const manifest = readConfig(file);
  return {name, dir, manifest, rawDir: join(root, 'raw', name), referenceDir: join(dir, 'reference')};
}

/** The terminal variant suffix for a theme and a frame: "", "-dark", "-portrait" or "-dark-portrait". */
export const terminalVariant = ({dark, narrow}) => `${dark ? '-dark' : ''}${narrow ? '-portrait' : ''}`;

/**
 * Finds a clip of an adapter: your own recording (raw/<adapter>/) first, then the committed reference. Terminal
 * clips use the variant for the theme and frame, falling back to the plain one. Returns {kind, file, meta, note} or null.
 */
export function resolveClip(adapter, clip, {dark = false, narrow = false} = {}) {
  const spec = adapter.manifest.clips?.[clip];
  if (!spec) return null;
  const candidates =
    spec.kind === 'terminal'
      ? [terminalVariant({dark, narrow}), ''].map((v) => ({stem: `${clip}${v}`, ext: 'mp4'}))
      : [{stem: clip, ext: spec.kind === 'app' ? 'mov' : spec.kind === 'browser' ? 'webm' : 'mp4'}];
  for (const [i, c] of candidates.entries()) {
    const places = [
      {file: join(adapter.rawDir, `${c.stem}.${c.ext}`), meta: join(adapter.rawDir, `${clip}.json`)},
      {file: join(adapter.referenceDir, `${c.stem}.mp4`), meta: join(adapter.referenceDir, `${clip}.json`)},
    ];
    const hit = places.find((p) => existsSync(p.file));
    if (hit) return {kind: spec.kind, file: hit.file, meta: existsSync(hit.meta) ? hit.meta : null, note: i > 0 ? `no ${candidates[0].stem} clip; using ${c.stem}` : null};
  }
  return null;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [name] = process.argv.slice(2).filter((a) => !a.startsWith('--'));
  const clip = process.argv.includes('--clip') ? process.argv[process.argv.indexOf('--clip') + 1] : undefined;
  try {
    const a = loadAdapter(name);
    const spec = clip ? a.manifest.clips[clip] : undefined;
    if (clip && !spec) throw new Error(`adapter "${name}" has no clip "${clip}" (${Object.keys(a.manifest.clips).join(', ')})`);
    if (process.argv.includes('--env')) {
      const vars = {
        ADAPTER_DIR: a.dir, RAW_DIR: a.rawDir, REFERENCE_DIR: a.referenceDir,
        TAPE: spec?.tape ? join(a.dir, spec.tape) : '', HIDE_FROM_LINE: spec?.hideFromLine ?? '',
        RECORD_APP: spec?.record ? join(a.dir, spec.record) : '',
      };
      console.log(Object.entries(vars).map(([k, v]) => `export ${k}='${v}'`).join('\n'));
    } else {
      console.log(`${a.name}: ${a.manifest.description}`);
      for (const [c, s] of Object.entries(a.manifest.clips)) console.log(`  ${c.padEnd(10)} ${s.kind}`);
    }
  } catch (e) {
    console.error(String(e.message));
    process.exit(1);
  }
}
