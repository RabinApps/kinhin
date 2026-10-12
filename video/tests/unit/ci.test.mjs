import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {DEFAULT_CONFIG, loadConfig, plan, validateConfig} from '../../scripts/video-ci.mjs';
import {projectNames, repo, root, run, themeNames} from '../helpers.mjs';

const config = (over = {}) => ({
  ...DEFAULT_CONFIG,
  enabled: true,
  triggers: {release: true, pullRequest: true, schedule: true},
  previewPaths: ['video/**', 'docs/making-a-video.md'],
  preview: [{project: 'examples/hello', looks: [{}]}],
  projects: [{project: 'launch', looks: [{}, {theme: 'midnight', format: '9:16'}, {format: '4:5'}]}],
  publish: {release: true, site: false},
  ...over,
});
const on = {VIDEO_CI: 'true', GITHUB_REPOSITORY: 'o/r'};

test('the committed ci.json is valid and opted out', () => {
  const c = loadConfig();
  assert.equal(c.enabled, false);
  assert.deepEqual(c.triggers, {release: false, pullRequest: false, schedule: false});
  assert.deepEqual(c.publish, {release: false, site: false});
  assert.deepEqual(validateConfig(c, {themes: themeNames(), projects: projectNames()}), []);
});

test('nothing builds unless the VIDEO_CI variable is true, whatever else is set', () => {
  for (const e of ['workflow_dispatch', 'workflow_run', 'pull_request', 'schedule']) {
    for (const v of [undefined, '', 'false', 'TRUE', '1']) {
      const r = plan({env: {VIDEO_CI: v, GITHUB_EVENT_NAME: e}, event: {}, config: config()});
      assert.equal(r.enabled, false, `${e} with VIDEO_CI=${v}`);
      assert.deepEqual(r.matrix, []);
    }
  }
});

test('a manual dispatch builds exactly what was asked for, even with ci.json disabled', () => {
  const r = plan({env: {...on, GITHUB_EVENT_NAME: 'workflow_dispatch', INPUT_PROJECT: 'examples/hello', INPUT_THEME: 'chalk', INPUT_FORMAT: '4:5'}, event: {}, config: config({enabled: false})});
  assert.equal(r.enabled, true);
  assert.deepEqual(r.matrix, [{project: 'examples/hello', theme: 'chalk', format: '4:5', adapter: '', name: 'examples-hello-chalk-4x5'}]);
  const dflt = plan({env: {...on, GITHUB_EVENT_NAME: 'workflow_dispatch'}, event: {}, config: config()});
  assert.equal(dflt.matrix[0].project, 'launch', 'falls back to the first configured project');
});

test('a release builds every configured look, only when enabled, on, and the release succeeded', () => {
  const ev = (conclusion) => ({workflow_run: {conclusion}});
  const r = plan({env: {...on, GITHUB_EVENT_NAME: 'workflow_run'}, event: ev('success'), config: config()});
  assert.deepEqual(r.matrix.map((m) => m.name), ['launch', 'launch-midnight-9x16', 'launch-4x5']);
  assert.deepEqual(r.publish, {release: true, site: false});
  assert.equal(plan({env: {...on, GITHUB_EVENT_NAME: 'workflow_run'}, event: ev('failure'), config: config()}).enabled, false);
  assert.equal(plan({env: {...on, GITHUB_EVENT_NAME: 'workflow_run'}, event: ev('success'), config: config({enabled: false})}).enabled, false);
  assert.equal(plan({env: {...on, GITHUB_EVENT_NAME: 'workflow_run'}, event: ev('success'), config: config({triggers: {release: false, pullRequest: true, schedule: true}})}).enabled, false);
});

test('pull requests: same-repository only, with the label or a changed path, and only the preview set', () => {
  const pr = (over = {}) => ({pull_request: {head: {repo: {full_name: 'o/r'}}, labels: [], ...over}});
  const env = {...on, GITHUB_EVENT_NAME: 'pull_request'};
  assert.equal(plan({env, event: pr({labels: [{name: 'video-preview'}]}), config: config()}).enabled, true);
  assert.deepEqual(plan({env, event: pr({labels: [{name: 'video-preview'}]}), config: config()}).matrix.map((m) => m.project), ['examples/hello']);
  assert.equal(plan({env: {...env, CHANGED_FILES: 'video/themes/paper.json\nREADME.md'}, event: pr(), config: config()}).enabled, true, 'a changed previewPaths file');
  assert.equal(plan({env: {...env, CHANGED_FILES: 'docs/making-a-video.md'}, event: pr(), config: config()}).enabled, true);
  assert.equal(plan({env: {...env, CHANGED_FILES: 'Sources/KinhinKit/x.swift'}, event: pr(), config: config()}).enabled, false, 'unrelated change');
  assert.equal(plan({env, event: pr(), config: config()}).enabled, false, 'no label, no path');
  assert.equal(plan({env, event: pr({head: {repo: {full_name: 'fork/r'}}, labels: [{name: 'video-preview'}]}), config: config()}).enabled, false, 'forks never build');
  assert.equal(plan({env, event: pr({labels: [{name: 'video-preview'}]}), config: config({triggers: {release: true, pullRequest: false, schedule: true}})}).enabled, false);
});

test('a schedule builds only when its switch is on; unknown events never build', () => {
  assert.equal(plan({env: {...on, GITHUB_EVENT_NAME: 'schedule'}, event: {}, config: config()}).enabled, true);
  assert.equal(plan({env: {...on, GITHUB_EVENT_NAME: 'schedule'}, event: {}, config: config({triggers: {release: true, pullRequest: true, schedule: false}})}).enabled, false);
  assert.equal(plan({env: {...on, GITHUB_EVENT_NAME: 'push'}, event: {}, config: config()}).enabled, false);
});

test('validateConfig names every problem', () => {
  const ctx = {themes: themeNames(), projects: projectNames()};
  const bad = {...DEFAULT_CONFIG, enabled: 'yes', triggers: {release: 1}, projects: [{project: 'nope'}, {looks: [{}]}, {project: 'launch', looks: [{theme: 'neon', format: '21:9'}]}], budgets: {mp4MB: 0}};
  const text = validateConfig(bad, ctx).join('\n');
  for (const piece of ['"enabled" must be true or false', 'triggers.release must be', 'no project "nope"', 'has no "project"', 'unknown theme "neon"', 'unknown format "21:9"', 'budgets.mp4MB']) assert.match(text, new RegExp(piece));
});

// The workflow's policies, checked as text: no secrets, forks and pull_request_target excluded, every action pinned to a
// commit, the opt-in switch present, and nothing inlining untrusted input into a script.
const yml = readFileSync(join(repo, '.github/workflows/video.yml'), 'utf8');

test('video.yml is opt-in, least-privilege and pinned', () => {
  assert.match(yml, /VIDEO_CI: \$\{\{ vars\.VIDEO_CI \}\}/, 'reads the opt-in variable');
  assert.doesNotMatch(yml, /pull_request_target/, 'never runs with a fork token');
  assert.doesNotMatch(yml, /secrets\./, 'needs no secrets');
  assert.match(yml, /^permissions:\n  contents: read/m, 'read-only by default');
  const uses = [...yml.matchAll(/uses: (\S+)/g)].map((m) => m[1]);
  assert.ok(uses.length >= 5);
  for (const u of uses) assert.match(u, /@[0-9a-f]{40}$/, `${u} is pinned to a commit`);
  for (const job of ['publish-release', 'publish-site']) assert.match(yml, new RegExp(`${job}:[\\s\\S]*?environment: marketing`), `${job} is behind the marketing environment`);
  assert.doesNotMatch(yml.replace(/\$\{\{ matrix\.name \}\}/g, ''), /run: [^\n]*\$\{\{ (inputs|github\.event\.pull_request|matrix)\./, 'no untrusted input inlined into a run line');
});

test('video.yml is not a dependency of the other workflows', () => {
  for (const f of ['ci.yml', 'release.yml', 'docs.yml', 'e2e.yml']) {
    assert.doesNotMatch(readFileSync(join(repo, '.github/workflows', f), 'utf8'), /video\.yml|workflows:\s*\[?\s*"Video"|needs:.*\bvideo\b/, `${f} does not depend on the Video workflow`);
  }
});

test('the plan step writes what the workflow reads: enabled, a fromJSON-able matrix, and the publish switches', () => {
  const dir = mkdtempSync(join(tmpdir(), 'plan-'));
  const out = join(dir, 'output');
  const event = join(dir, 'event.json');
  writeFileSync(out, '');
  writeFileSync(event, JSON.stringify({workflow_run: {conclusion: 'success'}}));
  const cfg = join(root, 'ci.json');
  const original = readFileSync(cfg, 'utf8');
  try {
    writeFileSync(cfg, JSON.stringify({enabled: true, triggers: {release: true}, projects: [{project: 'launch', looks: [{}, {theme: 'midnight', format: '9:16'}]}], publish: {release: true, site: false}}));
    const r = run('node', ['scripts/video-ci.mjs', 'plan'], {env: {VIDEO_CI: 'true', GITHUB_EVENT_NAME: 'workflow_run', GITHUB_EVENT_PATH: event, GITHUB_OUTPUT: out, GITHUB_REPOSITORY: 'o/r'}});
    assert.equal(r.status, 0, r.stderr);
    const lines = Object.fromEntries(readFileSync(out, 'utf8').trim().split('\n').map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]));
    assert.equal(lines.enabled, 'true');
    const matrix = JSON.parse(lines.matrix);
    assert.deepEqual(Object.keys(matrix), ['include']);
    assert.deepEqual(matrix.include.map((m) => m.name), ['launch', 'launch-midnight-9x16']);
    assert.deepEqual([lines.publish_release, lines.publish_site], ['true', 'false']);
    // And disabled, nothing to build: the workflow's `if` sees enabled=false.
    writeFileSync(out, '');
    run('node', ['scripts/video-ci.mjs', 'plan'], {env: {VIDEO_CI: '', GITHUB_EVENT_NAME: 'workflow_run', GITHUB_EVENT_PATH: event, GITHUB_OUTPUT: out}});
    assert.match(readFileSync(out, 'utf8'), /^enabled=false$/m);
  } finally {
    writeFileSync(cfg, original);
    rmSync(dir, {recursive: true, force: true});
  }
});
