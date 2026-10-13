#!/usr/bin/env node
// The brain of .github/workflows/video.yml, kept in a script so it can be tested here and the YAML stays thin.
//
//   node scripts/video-ci.mjs validate               check video/ci.json (scripts/check.sh runs this)
//   node scripts/video-ci.mjs plan                   decide whether to run and what to build; prints and, in Actions,
//                                                    writes `enabled` and `matrix` to $GITHUB_OUTPUT
//   node scripts/video-ci.mjs verify <out dir>       run scripts/verify.mjs on every video in a directory (out/<name>/<name>.mp4), with the budgets
//   node scripts/video-ci.mjs summary <out dir>      write a markdown table of the results ($GITHUB_STEP_SUMMARY in Actions)
//
// Everything is opt-in. Nothing runs unless the Actions variable VIDEO_CI is "true"; then each event needs its own switch
// in ci.json: triggers.release, triggers.pullRequest (and a same-repository PR with the "video-preview" label or a changed
// path in previewPaths), triggers.schedule. A manual dispatch always builds exactly what was asked for. Fork pull
// requests never build. See docs/plans/marketing-suite-in-ci.md.
//
// Environment (the plan step): VIDEO_CI, GITHUB_EVENT_NAME, GITHUB_EVENT_PATH (the event payload), GITHUB_REPOSITORY,
// CHANGED_FILES (newline-separated paths, for pull requests), INPUT_PROJECT / INPUT_THEME / INPUT_FORMAT / INPUT_ADAPTER.
import {appendFileSync, existsSync, readFileSync, readdirSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {FORMATS} from '../shared/resolve.mjs';
import {loadProject, root} from './project.mjs';
import {verifyVideo} from './verify.mjs';

export const DEFAULT_CONFIG = {
  enabled: false,
  triggers: {release: false, pullRequest: false, schedule: false},
  previewPaths: ['video/**'],
  preview: [],
  projects: [],
  publish: {release: false, site: false},
  budgets: {mp4MB: 10, seconds: 90, buildMinutes: 20},
};

export function loadConfig(file = join(root, 'ci.json')) {
  const raw = existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : {};
  return {...DEFAULT_CONFIG, ...raw, triggers: {...DEFAULT_CONFIG.triggers, ...raw.triggers}, publish: {...DEFAULT_CONFIG.publish, ...raw.publish}, budgets: {...DEFAULT_CONFIG.budgets, ...raw.budgets}};
}

/** What is wrong with a ci.json, in words. */
export function validateConfig(config, {themes = [], projects = []} = {}) {
  const problems = [];
  if (typeof config.enabled !== 'boolean') problems.push('"enabled" must be true or false');
  for (const [k, v] of Object.entries(config.triggers)) if (typeof v !== 'boolean') problems.push(`triggers.${k} must be true or false`);
  const lists = [['projects', config.projects], ['preview', config.preview]];
  for (const [label, list] of lists) {
    if (!Array.isArray(list)) problems.push(`"${label}" must be a list`);
    else for (const [i, entry] of list.entries()) {
      const where = `${label}[${i}]`;
      if (!entry.project) problems.push(`${where} has no "project"`);
      else if (projects.length && !projects.includes(entry.project)) problems.push(`${where}: no project "${entry.project}" in video/script/`);
      for (const look of entry.looks ?? [{}]) {
        if (look.format && !(look.format in FORMATS)) problems.push(`${where}: unknown format "${look.format}"`);
        if (look.theme && themes.length && !themes.includes(look.theme)) problems.push(`${where}: unknown theme "${look.theme}"`);
      }
    }
  }
  for (const k of ['mp4MB', 'seconds', 'buildMinutes']) if (!(config.budgets[k] > 0)) problems.push(`budgets.${k} must be a positive number`);
  return problems;
}

const slugOf = (e) => [e.project.replace(/\//g, '-'), e.theme, e.format?.replace(':', 'x')].filter(Boolean).join('-');
const expand = (list) => list.flatMap((entry) => (entry.looks ?? [{}]).map((look) => ({project: entry.project, theme: look.theme ?? '', format: look.format ?? '', adapter: look.adapter ?? entry.adapter ?? '', name: slugOf({project: entry.project, ...look}), screens: !!look.screens})));

/**
 * Decides what a workflow run does. `event` is the parsed GitHub event payload. Returns {enabled, reason, matrix}.
 * Pure: the tests call it with made-up environments.
 */
export function plan({env, event = {}, config}) {
  const off = (reason) => ({enabled: false, reason, matrix: []});
  if (env.VIDEO_CI !== 'true') return off('the Actions variable VIDEO_CI is not "true"');
  const name = env.GITHUB_EVENT_NAME;
  if (name === 'workflow_dispatch') {
    const project = env.INPUT_PROJECT || config.projects[0]?.project;
    if (!project) return off('no project given and none configured');
    const entry = {project, theme: env.INPUT_THEME || '', format: env.INPUT_FORMAT || '', adapter: env.INPUT_ADAPTER || ''};
    return {enabled: true, reason: 'manual dispatch', matrix: [{...entry, name: slugOf(entry)}]};
  }
  if (!config.enabled) return off('video/ci.json has "enabled": false');
  if (name === 'workflow_run' || name === 'release') {
    if (!config.triggers.release) return off('triggers.release is off');
    if (event.workflow_run && event.workflow_run.conclusion !== 'success') return off('the release workflow did not succeed');
    return {enabled: true, reason: 'a release was published', matrix: expand(config.projects), publish: {release: !!config.publish.release, site: !!config.publish.site}};
  }
  if (name === 'pull_request') {
    if (!config.triggers.pullRequest) return off('triggers.pullRequest is off');
    const pr = event.pull_request ?? {};
    if (pr.head?.repo?.full_name && pr.head.repo.full_name !== env.GITHUB_REPOSITORY) return off('pull requests from forks never build');
    const labeled = (pr.labels ?? []).some((l) => l.name === 'video-preview');
    const changed = (env.CHANGED_FILES ?? '').split('\n').filter(Boolean);
    const globs = (config.previewPaths ?? []).map((g) => new RegExp(`^${g.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*/g, '\u0000').replace(/\*/g, '[^/]*').replace(/\u0000/g, '.*')}$`));
    const touched = changed.some((f) => globs.some((re) => re.test(f)));
    if (!labeled && !touched) return off('no "video-preview" label and no changed path in previewPaths');
    return {enabled: true, reason: labeled ? 'the video-preview label' : 'a previewPaths file changed', matrix: expand(config.preview)};
  }
  if (name === 'schedule') {
    if (!config.triggers.schedule) return off('triggers.schedule is off');
    return {enabled: true, reason: 'the schedule', matrix: expand(config.projects)};
  }
  return off(`event "${name}" is not one this workflow builds for`);
}

function setOutput(key, value) {
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${typeof value === 'string' ? value : JSON.stringify(value)}\n`);
}

/** Every finished video under <out dir>: each lives in its own folder, out/<name>/<name>.mp4 with its <name>.srt beside it. */
function videosIn(dir) {
  return readdirSync(dir, {withFileTypes: true})
    .filter((e) => e.isDirectory() && !e.name.startsWith('.') && existsSync(join(dir, e.name, `${e.name}.mp4`)) && existsSync(join(dir, e.name, `${e.name}.srt`)))
    .map((e) => join(dir, e.name, `${e.name}.mp4`)).sort();
}

function verifyDir(dir, config) {
  const timelineFile = join(dir, '.work', 'timeline.json');
  const timeline = existsSync(timelineFile) ? JSON.parse(readFileSync(timelineFile, 'utf8')) : undefined;
  // The timeline belongs to the build that wrote it (its outName); other videos in the directory get the generic checks.
  return videosIn(dir).map((file) => ({file, ...verifyVideo(file, {timeline: timeline && file.endsWith(`/${timeline.outName}.mp4`) ? timeline : undefined, maxMB: config.budgets.mp4MB, maxSeconds: config.budgets.seconds})}));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [cmd, arg] = process.argv.slice(2);
  const config = loadConfig();
  if (cmd === 'validate') {
    const themes = readdirSync(join(root, 'themes')).filter((f) => f.endsWith('.json')).map((f) => f.replace(/\.json$/, ''));
    const walk = (d, p = '') => readdirSync(join(d)).flatMap((n) => (n.endsWith('.json') ? [`${p}${n.replace(/\.json$/, '')}`] : !n.includes('.') ? walk(join(d, n), `${p}${n}/`) : []));
    const problems = validateConfig(config, {themes, projects: walk(join(root, 'script'))});
    if (problems.length) { console.error(problems.map((p) => `ci.json: ${p}`).join('\n')); process.exit(1); }
    console.log(`ci.json ok (enabled: ${config.enabled})`);
  } else if (cmd === 'plan') {
    const event = process.env.GITHUB_EVENT_PATH && existsSync(process.env.GITHUB_EVENT_PATH) ? JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8')) : {};
    const result = plan({env: process.env, event, config});
    console.log(`${result.enabled ? 'build' : 'skip'}: ${result.reason}`);
    for (const m of result.matrix) console.log(`  ${m.name}  (${m.project}${m.theme ? `, ${m.theme}` : ''}${m.format ? `, ${m.format}` : ''})`);
    setOutput('enabled', String(result.enabled && result.matrix.length > 0));
    setOutput('matrix', {include: result.matrix});
    setOutput('publish_release', String(!!result.publish?.release));
    setOutput('publish_site', String(!!result.publish?.site));
    // A look with `screens` needs the mobile-capture job's PNGs (the workflow captures them before the build).
    setOutput('screens', String(result.matrix.some((m) => m.screens)));
  } else if (cmd === 'verify' || cmd === 'summary') {
    if (!arg) { console.error(`usage: video-ci.mjs ${cmd} <out dir>`); process.exit(2); }
    const results = verifyDir(arg, config);
    if (!results.length) { console.error(`no finished videos in ${arg}`); process.exit(1); }
    const bad = results.filter((r) => r.failures.length);
    if (cmd === 'verify') {
      for (const r of results) console.log(`${r.failures.length ? 'FAIL' : 'ok  '} ${r.file}\n${r.failures.map((f) => `       ${f}`).join('\n')}`.trimEnd());
      process.exit(bad.length ? 1 : 0);
    }
    const rows = results.map((r) => `| ${r.failures.length ? ':x:' : ':white_check_mark:'} | \`${r.file.split('/').pop()}\` | ${r.facts.width}×${r.facts.height} | ${r.facts.seconds} s | ${(r.facts.bytes / 1048576).toFixed(1)} MB | ${r.facts.lufs ?? '?'} | ${r.facts.captions ?? '?'} | ${r.failures.join('; ')} |`);
    const md = ['## Video build', '', '| | File | Size | Length | Weight | LUFS | Captions | Problems |', '|---|---|---|---|---|---|---|---|', ...rows, ''].join('\n');
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, md);
    console.log(md);
    process.exit(bad.length ? 1 : 0);
  } else {
    console.error('usage: video-ci.mjs validate | plan | verify <dir> | summary <dir>');
    process.exit(2);
  }
}
