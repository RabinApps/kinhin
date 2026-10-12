#!/usr/bin/env node
// Records one clip of an adapter, whatever its kind, into video/raw/<adapter>/:
//   app       runs the adapter's "record" script (it writes <clip>.mov and <clip>.json)
//   browser   scripts/record-web.sh with the clip's scenario, serve command and runner (writes <clip>.webm)
//   terminal  scripts/record-terminal.sh (all four variants unless you pass flags after --)
// Then `scripts/make-reference.sh --adapter <name>` makes the small committed copy.
//
// Usage: node scripts/record-clip.mjs [--adapter NAME] --clip NAME [--runner local|docker|apple] [-- extra args]
//   --adapter  default: the project's adapter (VIDEO_ADAPTER / VIDEO_PROJECT)
//   --runner   browser clips: where the browser runs (default: the clip's "runner", else local)
//   extra args go to the recorder (an app recorder's seconds, record-terminal.sh flags)
import {execFileSync} from 'node:child_process';
import {mkdirSync, writeFileSync} from 'node:fs';
import {join, relative} from 'node:path';
import {loadAdapter} from './adapter.mjs';
import {loadProject, root} from './project.mjs';

const argv = process.argv.slice(2);
const dd = argv.indexOf('--');
const extra = dd >= 0 ? argv.slice(dd + 1) : [];
const own = dd >= 0 ? argv.slice(0, dd) : argv;
const opt = (name) => (own.includes(name) ? own[own.indexOf(name) + 1] : undefined);
const adapterName = opt('--adapter') || loadProject().adapter;
const clip = opt('--clip');
if (!adapterName || !clip) {
  console.error('usage: node scripts/record-clip.mjs [--adapter NAME] --clip NAME [--runner local|docker|apple] [-- extra args]');
  process.exit(2);
}
try {
  const adapter = loadAdapter(adapterName);
  const spec = adapter.manifest.clips[clip];
  if (!spec) throw new Error(`adapter "${adapterName}" has no clip "${clip}" (${Object.keys(adapter.manifest.clips).join(', ')})`);
  mkdirSync(adapter.rawDir, {recursive: true});
  const run = (cmd, args, env = {}) => execFileSync(cmd, args, {cwd: root, stdio: 'inherit', env: {...process.env, ...env}});

  if (spec.kind === 'app') {
    run(join(adapter.dir, spec.record), extra, {VIDEO_RAW_DIR: relative(join(root, '..'), adapter.rawDir)});
  } else if (spec.kind === 'terminal') {
    run('scripts/record-terminal.sh', ['--adapter', adapterName, '--clip', clip, ...(extra.length ? extra : ['--all'])]);
  } else if (spec.kind === 'browser') {
    const args = [
      '--scenario', relative(join(root, '..'), join(adapter.dir, spec.scenario)),
      '--out', relative(join(root, '..'), join(adapter.rawDir, `${clip}.webm`)),
      '--runner', opt('--runner') || spec.runner || 'local',
    ];
    if (spec.serve) args.push('--serve', spec.serve);
    if (spec.waitUrl) args.push('--wait-url', spec.waitUrl);
    run(join(root, 'scripts/record-web.sh'), args);
    writeFileSync(join(adapter.rawDir, `${clip}.json`), JSON.stringify({demoStartsAt: 0}) + '\n');
  } else {
    throw new Error(`clip "${clip}" has kind "${spec.kind}", which has no recorder`);
  }
} catch (e) {
  console.error(String(e.message));
  process.exit(1);
}
