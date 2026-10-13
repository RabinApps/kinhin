// End-to-end: real builds. Slow on purpose; the tier decides how much runs (see e2e.mjs, scripts/test.sh).
import assert from 'node:assert/strict';
import {mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {loadProject} from '../../scripts/project.mjs';
import {FORMATS} from '../../shared/resolve.mjs';
import {themeNames} from '../helpers.mjs';
import {existsSync} from 'node:fs';
import {bottomEdges, build, check, from, has, root, run, tempProject} from './e2e.mjs';

const expectGood = (name, extra = {}) => {
  const {failures, facts} = check(name, {maxMB: 10, ...extra});
  assert.deepEqual(failures, [], `${name}: ${failures.join('; ')}`);
  return facts;
};

// ---- smoke -----------------------------------------------------------------------------------------------------

test('smoke: the hello example builds, and every check passes', from('smoke'), () => {
  // A --fast build writes no WebM; stale ones from earlier builds must not mask a failure to cope with that (a glob that
  // matches nothing once made the build script exit 2).
  for (const d of readdirSync(join(root, 'out'), {withFileTypes: true})) {
    if (d.isDirectory()) for (const f of readdirSync(join(root, 'out', d.name))) if (f.endsWith('.webm')) rmSync(join(root, 'out', d.name, f));
  }
  const r = build(['--project', 'examples/hello', '--fast'], {env: {RENDER_FORCE: '1'}});
  assert.equal(r.status, 0, r.stdout.slice(-800) + r.stderr.slice(-800));
  assert.equal(r.name, 'examples-hello');
  const facts = expectGood(r.name);
  assert.ok(facts.seconds > 8 && facts.seconds < 40, `a short video, got ${facts.seconds} s`);
  assert.equal(facts.width, 1920);
  // The CI steps work on a real build: verify passes, and the summary is a markdown table with a check mark.
  const ci = run('node', ['scripts/video-ci.mjs', 'verify', 'out']);
  assert.match(ci.stdout, /^ok\s+out\/examples-hello\/examples-hello\.mp4/m, ci.stdout + ci.stderr);
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

test('smoke: captions can be switched off, restyled, and the caption file is written either way', from('smoke'), () => {
  // The template demo has a device scene with cues; look at the band under the laptop while a cue is spoken.
  const on = build(['--project', 'template-demo', '--fast']);
  assert.equal(on.status, 0, on.stdout.slice(-600));
  const timeline = JSON.parse(readFileSync(join(root, 'out/.work/timeline.json'), 'utf8'));
  const at = timeline.scenes.screen.start + 1.8;
  const withCaptions = bottomEdges(on.name, at);
  const off = build(['--project', 'template-demo', '--captions', 'off', '--fast']);
  assert.equal(off.status, 0, off.stdout.slice(-600));
  assert.equal(off.name, on.name);
  const without = bottomEdges(off.name, at);
  assert.ok(withCaptions > without * 3 && withCaptions > 0.002, `burned captions show up under the picture (${withCaptions} vs ${without})`);
  assert.ok(existsSync(join(root, `out/${off.name}/${off.name}.srt`)), 'the caption file is written with captions off');
  assert.deepEqual(check(off.name).failures, [], 'a captionless build still passes every check');
  // The kinhin adapter defaults to no burned-in captions; --captions on brings them back.
  const kinhin = build(['--project', 'examples/kinhin-30s', '--fast']);
  assert.equal(kinhin.status, 0, kinhin.stdout.slice(-600));
  const t2 = JSON.parse(readFileSync(join(root, 'out/.work/timeline.json'), 'utf8'));
  const kAt = t2.scenes.app.start + 1.8;
  const kOff = bottomEdges(kinhin.name, kAt);
  const kOn = build(['--project', 'examples/kinhin-30s', '--captions', 'on', '--fast']);
  assert.equal(kOn.status, 0, kOn.stdout.slice(-600));
  assert.ok(bottomEdges(kOn.name, kAt) > kOff * 3, 'the kinhin short has captions only when asked');
});

test('smoke: a caption style builds and looks different from the default', from('smoke'), () => {
  const outline = build(['--project', 'template-demo', '--fast']);
  const timeline = JSON.parse(readFileSync(join(root, 'out/.work/timeline.json'), 'utf8'));
  const at = timeline.scenes.screen.start + 1.8;
  const a = bottomEdges(outline.name, at);
  const box = build(['--project', 'template-demo', '--caption-style', 'box', '--fast']);
  assert.equal(box.status, 0, box.stdout.slice(-600));
  const b = bottomEdges(box.name, at);
  assert.notEqual(a.toFixed(4), b.toFixed(4), 'a different style is a different picture');
  assert.deepEqual(check(box.name).failures, []);
});

test('standard: a build needs no network once the image exists (voices, model, fonts, music, renderer are all baked in)', {...from('standard'), skip: !has('docker') && 'needs Docker (--network none)'}, () => {
  // Build the image first (with network), then cut the network for the build itself.
  const r = build(['--project', 'examples/hello', '--fast', '--runtime', 'docker'], {env: {CONTAINER_NETWORK: 'none'}});
  assert.equal(r.status, 0, r.stdout.slice(-900) + r.stderr.slice(-900));
  const facts = expectGood(r.name);
  assert.ok(facts.lufs !== null, 'with the music bed mixed in: it came from the image, not the network');
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
  const first = JSON.parse(readFileSync(join(root, 'out/.work/timeline.json'), 'utf8'));
  const b = build(['--project', 'examples/hello', '--fast']);
  const second = JSON.parse(readFileSync(join(root, 'out/.work/timeline.json'), 'utf8'));
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

test('smoke: a video built from your own repository (.kinhin/videos/ and your own music file)', from('smoke'), () => {
  const repo = mkdtempSync(join(tmpdir(), 'kinhin-e2e-repo-'));
  try {
    mkdirSync(join(repo, '.kinhin/videos'), {recursive: true});
    mkdirSync(join(repo, 'audio'));
    run('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=f=220:d=5', join(repo, 'audio/bed.wav')]);
    writeFileSync(join(repo, '.kinhin/videos/own.yml'),
      'name: Own\ntheme: clean\nvoice: {engine: kokoro, name: af_heart}\nmusic: {track: audio/bed.wav, volume: 0.2}\n' +
      'scenes:\n  - id: hi\n    type: title\n    props: {title: Mine}\n    narration: This video came from my own repository.\n');
    const r = build(['--source', repo, '--project', 'own', '--fast']);
    assert.equal(r.status, 0, r.stdout.slice(-800) + r.stderr.slice(-800));
    assert.equal(r.name, 'own');
    expectGood('own');
    const music = JSON.parse(readFileSync(join(root, 'out/.work/music.json'), 'utf8'));
    assert.equal(music.enabled, true);
    assert.match(music.file, /bed\.wav$/);
    assert.equal(music.volume, 0.2);
  } finally { rmSync(repo, {recursive: true, force: true}); }
});

test('smoke: a theme of your own (.kinhin/videos/themes/, extending a built-in one) is used by the title scenes and the frame', from('smoke'), () => {
  const repo = mkdtempSync(join(tmpdir(), 'kinhin-e2e-theme-'));
  try {
    mkdirSync(join(repo, '.kinhin/videos/themes'), {recursive: true});
    // Clean, with a solid red backdrop: easy to see in the finished poster, and nothing built in is red.
    writeFileSync(join(repo, '.kinhin/videos/themes/signal.yml'), 'extends: clean\nbackground:\n  from: "#ff0000"\n  to: "#ff0000"\ncolors:\n  paper: "#ff0000"\n  ink: "#ffffff"\n  muted: "#ffe0e0"\n');
    writeFileSync(join(repo, '.kinhin/videos/themed.yml'),
      'name: Themed\ntheme: signal\nvoice: {engine: kokoro, name: af_heart}\nmusic: false\n' +
      'scenes:\n  - id: hi\n    type: statement\n    props: {text: "A theme of its own", sub: "Colours, fonts and backdrop come from a file in your repository."}\n    narration: This one has a theme of its own.\n');
    const r = build(['--source', repo, '--project', 'themed', '--fast']);
    assert.equal(r.status, 0, r.stdout.slice(-800) + r.stderr.slice(-800));
    assert.match(r.stdout, /signal/, 'the build reports the theme it used');
    expectGood('themed');
    // The poster's average colour: a red backdrop, whatever the text on it.
    const px = spawnSync('ffmpeg', ['-nostdin', '-loglevel', 'error', '-i', join(root, 'out/themed/themed-poster.png'), '-vf', 'scale=1:1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']);
    assert.equal(px.status, 0, String(px.stderr));
    const [red, green, blue] = px.stdout;
    assert.ok(red > 150 && green < 120 && blue < 120, `a mostly red poster, got rgb(${red}, ${green}, ${blue})`);

    // A broken theme file fails fast and names the file and the problem, before anything renders.
    writeFileSync(join(repo, '.kinhin/videos/themes/oops.json'), JSON.stringify({colors: {ink: 'red'}}));
    const bad = build(['--source', repo, '--project', 'themed', '--fast']);
    assert.notEqual(bad.status, 0);
    assert.match(bad.stdout + bad.stderr, /theme "oops".*font\.family/s);
    assert.doesNotMatch(bad.stdout, /==> voice-over/);
  } finally { rmSync(repo, {recursive: true, force: true}); }
});
