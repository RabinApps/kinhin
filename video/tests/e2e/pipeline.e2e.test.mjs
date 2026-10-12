// End-to-end: real builds. Slow on purpose; the tier decides how much runs (see e2e.mjs, scripts/test.sh).
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';
import {test} from 'node:test';
import {loadProject} from '../../scripts/project.mjs';
import {FORMATS} from '../../shared/resolve.mjs';
import {themeNames} from '../helpers.mjs';
import {build, check, from, root, run, tempProject} from './e2e.mjs';

const expectGood = (name, extra = {}) => {
  const {failures, facts} = check(name, {maxMB: 10, ...extra});
  assert.deepEqual(failures, [], `${name}: ${failures.join('; ')}`);
  return facts;
};

// ---- smoke -----------------------------------------------------------------------------------------------------

test('smoke: the hello example builds, and every check passes', from('smoke'), () => {
  const r = build(['--project', 'examples/hello', '--fast'], {env: {RENDER_FORCE: '1'}});
  assert.equal(r.status, 0, r.stdout.slice(-800) + r.stderr.slice(-800));
  assert.equal(r.name, 'examples-hello');
  const facts = expectGood(r.name);
  assert.ok(facts.seconds > 8 && facts.seconds < 40, `a short video, got ${facts.seconds} s`);
  assert.equal(facts.width, 1920);
  // The CI steps work on a real build: verify passes, and the summary is a markdown table with a check mark.
  const ci = run('node', ['scripts/video-ci.mjs', 'verify', 'out']);
  assert.match(ci.stdout, /^ok\s+out\/examples-hello\.mp4/m, ci.stdout + ci.stderr);
  const summary = run('node', ['scripts/video-ci.mjs', 'summary', 'out']);
  assert.match(summary.stdout, /\| :white_check_mark: \| `examples-hello\.mp4` \| 1920×1080 \|/);
});

test('smoke: the template adapter builds with an app clip, a browser clip and a terminal clip', from('smoke'), () => {
  const r = build(['--project', 'template-demo', '--fast']);
  assert.equal(r.status, 0, r.stdout.slice(-800) + r.stderr.slice(-800));
  const facts = expectGood(r.name);
  const project = loadProject('template-demo');
  const cues = project.scenes.reduce((n, s) => n + (s.cues ? s.cues.length : (s.narration.match(/[^.!?]+[.!?]+/g) ?? [s.narration]).length), 0);
  assert.equal(facts.captions, cues, 'one caption per cue, including the clip scenes');
});

test('smoke: a claim the product cannot back fails fast, before anything renders', from('smoke'), () => {
  const bad = tempProject({name: 'bad claim', theme: 'paper', format: '16:9', scenes: [{id: 'a', type: 'statement', props: {text: 'Works with Buildkite.'}, narration: 'Works with Buildkite.'}], adapter: 'kinhin'});
  try {
    const r = build(['--project', bad.name, '--fast']);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout + r.stderr, /"Buildkite" is planned, not shipped/);
    assert.doesNotMatch(r.stdout, /==> voice-over/, 'stopped before the voice-over');
  } finally { bad.cleanup(); }
});

test('smoke: an unknown theme is named, with the themes that exist', from('smoke'), () => {
  const r = build(['--project', 'examples/hello', '--theme', 'neon', '--fast']);
  assert.notEqual(r.status, 0);
  assert.match(r.stdout + r.stderr, /unknown theme "neon".*paper/);
});

// ---- standard --------------------------------------------------------------------------------------------------

for (const [project, format] of [['examples/social-teaser', '9:16'], ['examples/oss-announcement', '4:5'], ['examples/changelog-month', '1:1']]) {
  test(`standard: ${project} is ${format} and every check passes`, from('standard'), () => {
    const r = build(['--project', project, '--fast']);
    assert.equal(r.status, 0, r.stdout.slice(-800) + r.stderr.slice(-800));
    const facts = expectGood(r.name);
    assert.deepEqual([facts.width, facts.height], [FORMATS[format].width, FORMATS[format].height]);
  });
}

for (const theme of themeNames()) {
  test(`standard: the hello example in the ${theme} theme`, from('standard'), () => {
    const r = build(['--project', 'examples/hello', '--theme', theme, '--fast']);
    assert.equal(r.status, 0, r.stdout.slice(-800) + r.stderr.slice(-800));
    assert.equal(r.name, `examples-hello-${theme}`);
    expectGood(r.name);
  });
}

test('standard: every scene type renders (the scene tour)', from('standard'), () => {
  const r = build(['--project', 'examples/scene-tour', '--fast']);
  assert.equal(r.status, 0, r.stdout.slice(-800) + r.stderr.slice(-800));
  const facts = expectGood(r.name, {maxSeconds: 90});
  assert.ok(facts.seconds > 40, `ten scenes take a while, got ${facts.seconds} s`);
});

test('standard: the kinhin short, from its adapter\'s reference clips', from('standard'), () => {
  const r = build(['--project', 'examples/kinhin-30s', '--fast']);
  assert.equal(r.status, 0, r.stdout.slice(-800) + r.stderr.slice(-800));
  expectGood(r.name);
});

test('standard: the command-line look overrides rename the output and change the frame', from('standard'), () => {
  const r = build(['--project', 'examples/hello', '--theme', 'midnight', '--format', '9:16', '--fast']);
  assert.equal(r.status, 0, r.stdout.slice(-800) + r.stderr.slice(-800));
  assert.equal(r.name, 'examples-hello-midnight-9x16');
  const facts = expectGood(r.name);
  assert.deepEqual([facts.width, facts.height], [1080, 1920]);
});

test('standard: a second build re-renders nothing, and changing one scene re-renders only that scene', from('standard'), () => {
  const base = JSON.parse(readFileSync(join(root, 'script/examples/hello.json'), 'utf8'));
  const t = tempProject({...base, name: 'cache test'});
  try {
    const first = build(['--project', t.name, '--fast']);
    assert.equal(first.status, 0, first.stdout.slice(-800));
    const second = build(['--project', t.name, '--fast']);
    assert.equal(second.status, 0, second.stdout.slice(-800));
    const cached = (second.stdout.match(/^cached\s/gm) ?? []).length;
    assert.equal(cached, base.scenes.length, `all ${base.scenes.length} scenes cached: ${second.stdout.slice(-600)}`);
    // Change one scene's words: the picture of the others must not be rebuilt.
    const edited = JSON.parse(JSON.stringify(base));
    edited.name = 'cache test';
    edited.scenes[1].props.text = 'A different sentence.';
    edited.scenes[1].narration = 'A different sentence.';
    writeFileSyncJson(t.file, edited);
    const third = build(['--project', t.name, '--fast']);
    assert.equal(third.status, 0, third.stdout.slice(-800));
    const rendered = (third.stdout.match(/^rendered\s/gm) ?? []).length;
    assert.ok(rendered >= 1 && rendered < base.scenes.length, `only the changed scene re-renders (rendered ${rendered} of ${base.scenes.length})`);
  } finally { t.cleanup(); }
});

test('standard: two builds of the same inputs give the same timeline', from('standard'), () => {
  const a = build(['--project', 'examples/hello', '--fast']);
  const first = JSON.parse(readFileSync(join(root, 'out/timeline.json'), 'utf8'));
  const b = build(['--project', 'examples/hello', '--fast']);
  const second = JSON.parse(readFileSync(join(root, 'out/timeline.json'), 'utf8'));
  assert.equal(a.status + b.status, 0);
  assert.deepEqual(Object.fromEntries(Object.entries(first.scenes).map(([k, v]) => [k, v.length])), Object.fromEntries(Object.entries(second.scenes).map(([k, v]) => [k, v.length])));
  assert.ok(Math.abs(first.total - second.total) < 0.05);
});

// ---- full ------------------------------------------------------------------------------------------------------

test('full: the kinhin launch video, every look the CI config builds', from('full'), () => {
  for (const args of [[], ['--theme', 'midnight', '--format', '9:16'], ['--format', '4:5']]) {
    const r = build(['--project', 'launch', ...args]);
    assert.equal(r.status, 0, r.stdout.slice(-800) + r.stderr.slice(-800));
    expectGood(r.name, {maxSeconds: 90});
  }
});

for (const example of ['product-launch', 'release-notes', 'tutorial-chalk', 'architecture-blueprint', 'code-walkthrough']) {
  test(`full: the ${example} example`, from('full'), () => {
    const r = build(['--project', `examples/${example}`, '--fast']);
    assert.equal(r.status, 0, r.stdout.slice(-800) + r.stderr.slice(-800));
    expectGood(r.name);
  });
}

import {writeFileSync} from 'node:fs';
function writeFileSyncJson(file, value) { writeFileSync(file, JSON.stringify(value, null, 2)); }
