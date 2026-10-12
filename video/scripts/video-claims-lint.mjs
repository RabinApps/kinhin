#!/usr/bin/env node
// The honesty gate for video text: fails when a project says something its product does not support. Rules come from
// the project's adapter (adapters/<name>/claims.json) and, optionally, a "claims" object in the project file:
//   planned          names that are on the roadmap but not shipped: allowed only in a sentence that says so
//   plannedMarkers   the words that make mentioning a planned name honest ("planned", "roadmap", ...)
//   forbidden        tone words a video should not use ("fastest", "enterprise-grade", ...)
// Every string a viewer can hear or read is checked: narration, cues, and every string in a scene's props.
//
// Usage: node scripts/video-claims-lint.mjs [--all | --project NAME]      Exit 1 when anything fails.
//        scripts/check.sh runs it with --all, so the main branch cannot carry an unsupported claim in a video script.
import {existsSync, readFileSync, readdirSync, statSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {loadAdapter} from './adapter.mjs';
import {loadProject, root} from './project.mjs';

/** Every sentence a scene shows or says, with where it came from. */
export function textsOf(project) {
  const out = [];
  const walk = (value, where) => {
    if (typeof value === 'string') out.push({where, text: value});
    else if (Array.isArray(value)) value.forEach((v, i) => walk(v, `${where}[${i}]`));
    else if (value && typeof value === 'object') for (const [k, v] of Object.entries(value)) walk(v, `${where}.${k}`);
  };
  for (const scene of project.scenes) {
    if (scene.narration) walk(scene.narration, `${scene.id}.narration`);
    for (const [i, cue] of (scene.cues ?? []).entries()) {
      walk(cue.text, `${scene.id}.cues[${i}]`);
      if (cue.say) walk(cue.say, `${scene.id}.cues[${i}].say`);
    }
    // props that name files or settings are not shown
    const {clip, frame, mark, speed, ...shown} = scene.props ?? {};
    walk(shown, `${scene.id}.props`);
  }
  return out;
}

export function lintProject(project, claims = {}) {
  const problems = [];
  const planned = claims.planned ?? [];
  const markers = (claims.plannedMarkers ?? ['planned', 'roadmap']).map((m) => m.toLowerCase());
  const word = (term) => new RegExp(`(^|[^\\w])${term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}($|[^\\w])`, 'i');
  for (const {where, text} of textsOf(project)) {
    for (const name of planned) {
      if (word(name).test(text) && !markers.some((m) => text.toLowerCase().includes(m))) {
        problems.push(`${where}: "${name}" is planned, not shipped; say so ("planned") or remove it: ${JSON.stringify(text)}`);
      }
    }
    for (const term of claims.forbidden ?? []) {
      if (word(term).test(text)) problems.push(`${where}: avoid "${term}": ${JSON.stringify(text)}`);
    }
  }
  return problems;
}

/** Claims for a loaded project: its adapter's claims.json merged with the project's own "claims". */
export function claimsFor(loaded) {
  let claims = {};
  if (loaded.adapter) {
    const file = join(loadAdapter(loaded.adapter).dir, 'claims.json');
    if (existsSync(file)) claims = JSON.parse(readFileSync(file, 'utf8'));
  }
  const own = loaded.project.claims ?? {};
  return {planned: [...(claims.planned ?? []), ...(own.planned ?? [])], plannedMarkers: claims.plannedMarkers ?? own.plannedMarkers, forbidden: [...(claims.forbidden ?? []), ...(own.forbidden ?? [])]};
}

function allProjects(dir = join(root, 'script'), prefix = '') {
  return readdirSync(dir).flatMap((n) => (statSync(join(dir, n)).isDirectory() ? allProjects(join(dir, n), `${prefix}${n}/`) : n.endsWith('.json') ? [`${prefix}${n.replace(/\.json$/, '')}`] : []));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const names = args.includes('--project') ? [args[args.indexOf('--project') + 1]] : args.includes('--all') ? allProjects() : [process.env.VIDEO_PROJECT || 'launch'];
  let failed = 0;
  for (const name of names) {
    const loaded = loadProject(name);
    const problems = lintProject(loaded.project, claimsFor(loaded));
    console.log(`${problems.length ? 'FAIL' : 'ok  '} ${name}${loaded.adapter ? ` (${loaded.adapter})` : ''}`);
    for (const p of problems) console.log(`       ${p}`);
    failed += problems.length;
  }
  process.exit(failed ? 1 : 0);
}
