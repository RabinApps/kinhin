import assert from 'node:assert/strict';
import {existsSync} from 'node:fs';
import {join} from 'node:path';
import {test} from 'node:test';
import {loadAdapter, resolveClip} from '../../scripts/adapter.mjs';
import {listSourceProjects, loadProject, loadThemes, shellEnv, userThemeNames} from '../../scripts/project.mjs';
import {projectNames, readJson, root, themeNames} from '../helpers.mjs';

const themeFile = (name) => readJson(join(root, 'themes', `${name}.json`));

const projects = projectNames();

test('there are many example projects, and each one loads', () => {
  assert.ok(projects.filter((p) => p.startsWith('examples/')).length >= 10, `examples: ${projects.join(', ')}`);
  for (const name of projects) {
    const p = loadProject(name);
    assert.ok(p.scenes.length > 0, name);
    assert.ok(themeNames().includes(p.theme.name), `${name}: theme ${p.theme.name}`);
  }
});

test('the examples cover every theme, every format and every scene type', () => {
  const loaded = projects.map((n) => loadProject(n));
  const themes = new Set(loaded.map((p) => p.theme.name));
  const formats = new Set(loaded.map((p) => p.format.name));
  const types = new Set(loaded.flatMap((p) => p.scenes.map((s) => s.type)));
  for (const t of themeNames()) assert.ok(themes.has(t), `theme ${t}`);
  for (const f of ['16:9', '9:16', '4:5', '1:1']) assert.ok(formats.has(f), `format ${f}`);
  for (const t of ['title', 'statement', 'queue', 'parallel', 'map', 'outro', 'stats', 'steps', 'code', 'compare', 'device', 'terminal']) assert.ok(types.has(t), `scene type ${t}`);
});

test('every clip a project uses exists in its adapter (raw or reference) in the variants it needs', () => {
  for (const name of projects) {
    const p = loadProject(name);
    const clipScenes = p.scenes.filter((s) => s.kind === 'clip');
    if (!clipScenes.length) continue;
    assert.ok(p.adapter, `${name}: clip scenes need an adapter`);
    const adapter = loadAdapter(p.adapter);
    const narrow = p.format.width / p.format.height < 1.2;
    for (const s of clipScenes) {
      const found = resolveClip(adapter, s.props.clip, {dark: p.theme.device.terminal === 'dark', narrow});
      assert.ok(found, `${name}/${s.id}: no clip "${s.props.clip}" in ${p.adapter}`);
      assert.ok(existsSync(found.file));
    }
  }
});

test('output names carry a non-default theme or format', () => {
  const base = loadProject('launch');
  assert.equal(base.outName, 'launch');
  const saved = {t: process.env.VIDEO_THEME, f: process.env.VIDEO_FORMAT};
  process.env.VIDEO_THEME = 'midnight';
  process.env.VIDEO_FORMAT = '9:16';
  try {
    const p = loadProject('launch');
    assert.equal(p.outName, 'launch-midnight-9x16');
    assert.equal(p.theme.name, 'midnight');
    assert.equal(p.format.name, '9:16');
    assert.equal(loadProject('examples/hello').outName, 'examples-hello-midnight-9x16');
  } finally {
    saved.t === undefined ? delete process.env.VIDEO_THEME : (process.env.VIDEO_THEME = saved.t);
    saved.f === undefined ? delete process.env.VIDEO_FORMAT : (process.env.VIDEO_FORMAT = saved.f);
  }
});

test('shellEnv exports the look for the ffmpeg scripts', () => {
  const env = Object.fromEntries(shellEnv(loadProject('launch')).split('\n').map((l) => l.match(/^export (\w+)='(.*)'$/).slice(1)));
  assert.equal(env.VIDEO_W, '1920');
  assert.equal(env.VIDEO_NARROW, '0');
  assert.match(env.BG_FROM, /^0x[0-9a-f]{6}$/i);
  assert.match(env.CAPTION_TEXT, /^&H[0-9A-F]{6}&$/, 'ASS colours are &HBBGGRR&');
  assert.equal(env.TERMINAL_MODE, 'light');
});

test('an unknown project or a broken one fails with a useful message', () => {
  assert.throws(() => loadProject('does-not-exist'), /ENOENT|no such file|no video project/);
});

test('kinhin videos burn no captions; every other adapter keeps them, and the caption file is always available', () => {
  for (const name of projectNames()) {
    const p = loadProject(name);
    if (p.adapter === 'kinhin') assert.equal(p.captions.burn, false, `${name}: the kinhin adapter turns captions off`);
    else assert.equal(p.captions.burn, true, `${name}: captions on`);
    assert.equal(p.captions.sidecar, true, `${name}: the .srt is still written`);
  }
  // A project can opt back in, and the command line overrides either way.
  const saved = process.env.VIDEO_CAPTIONS;
  process.env.VIDEO_CAPTIONS = 'on';
  try { assert.equal(loadProject('launch').captions.burn, true); } finally { saved === undefined ? delete process.env.VIDEO_CAPTIONS : (process.env.VIDEO_CAPTIONS = saved); }
});

test('the kinhin adapter keeps First Light Particles, and a project can opt out or choose its own', async () => {
  const {resolveMusic} = await import('../../shared/resolve.mjs');
  const adapter = readJson(join(root, 'adapters/kinhin/adapter.json'));
  assert.equal(resolveMusic({project: {}, adapter, env: {}}).track, 'first-light-particles');
  assert.equal(resolveMusic({project: {music: false}, adapter, env: {}}).enabled, false);
  const catalog = readJson(join(root, 'music/catalog.json')).tracks;
  const t = catalog['first-light-particles'];
  assert.match(t.sha256, /^[0-9a-f]{64}$/);
  assert.equal(t.license, 'CC0-1.0');
});

// ---- your own repository: .kinhin/videos/ ---------------------------------------------------------------------------

import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';

function userRepo() {
  const dir = mkdtempSync(join(tmpdir(), 'kinhin-repo-'));
  const videos = join(dir, '.kinhin/videos');
  mkdirSync(join(videos, 'promo'), {recursive: true});
  mkdirSync(join(videos, 'adapters/acme'), {recursive: true});
  writeFileSync(join(videos, 'promo/intro.yml'), 'name: Acme intro\nadapter: acme\ntheme: midnight\nmusic:\n  track: music/bed.wav\nscenes:\n  - id: hi\n    type: title\n    props: {title: Acme}\n    narration: Acme ships.\n');
  writeFileSync(join(videos, 'short.json'), JSON.stringify({name: 'Short', scenes: [{id: 'a', type: 'title', props: {title: 'A'}, narration: 'A.'}]}));
  // Saved music has .json provenance files, and the build writes out/ and .cache/: none of them are videos.
  for (const f of ['music/bed.json', 'out/timeline.json', '.cache/scenes/x.json', 'fonts/info.json']) {
    mkdirSync(join(videos, f, '..'), {recursive: true});
    writeFileSync(join(videos, f), '{}');
  }
  writeFileSync(join(videos, 'adapters/acme/adapter.yml'), 'name: acme\nmusic:\n  volume: 0.2\nclips: {}\n');
  return dir;
}

test('a repository\'s .kinhin/videos/ holds its projects (YAML or JSON, subfolders) and its adapters', () => {
  const dir = userRepo();
  process.env.VIDEO_SOURCE = dir;
  try {
    const p = loadProject('promo/intro');
    assert.equal(p.stem, 'promo/intro');
    assert.equal(p.slug, 'promo-intro');
    assert.equal(p.theme.name, 'midnight');
    assert.equal(p.adapter, 'acme');
    assert.deepEqual([p.music.track, p.music.volume], ['music/bed.wav', 0.2], 'the project picks the track, the adapter sets the volume');
    assert.equal(loadProject('short').name, 'Short');
    assert.equal(loadAdapter('acme').manifest.name, 'acme');
    assert.throws(() => loadProject('nope'), /no video project "nope".*promo\/intro, short\)/, 'only real videos are listed');
    assert.equal(loadProject('launch').name !== undefined, true, 'the built-in projects still resolve');
  } finally { delete process.env.VIDEO_SOURCE; rmSync(dir, {recursive: true, force: true}); }
});

test('without a repository, nothing changes', () => {
  assert.throws(() => loadProject('promo/intro'), /no video project/);
});

test('your own themes in .kinhin/videos/themes/ are loaded, extended and chosen by a video', () => {
  const dir = userRepo();
  const themes = join(dir, '.kinhin/videos/themes');
  mkdirSync(themes, {recursive: true});
  writeFileSync(join(themes, 'brand.yml'), 'extends: midnight\ncolors:\n  accent: "#ff7a59"\nbackground:\n  from: "#101010"\n  to: "#202020"\n');
  writeFileSync(join(themes, 'plain.json'), JSON.stringify({extends: 'paper', font: {family: 'Georgia'}}));
  writeFileSync(join(dir, '.kinhin/videos/mine.yml'), 'name: Mine\ntheme: brand\noverrides:\n  colors: {ink: "#eeeeee"}\nscenes:\n  - id: a\n    type: title\n    props: {title: A}\n    narration: A.\n');
  process.env.VIDEO_SOURCE = dir;
  try {
    const p = loadProject('mine');
    assert.equal(p.theme.name, 'brand');
    assert.equal(p.theme.colors.accent, '#ff7a59', 'from the theme file');
    assert.equal(p.theme.colors.ink, '#eeeeee', 'the video\'s overrides still win');
    assert.equal(p.theme.colors.card, themeFile('midnight').colors.card, 'the rest from the theme it extends');
    assert.equal(loadProject('mine').theme.device.terminal, 'dark');
    assert.deepEqual(listSourceProjects(), ['mine', 'promo/intro', 'short'], 'the theme files are not videos');
    assert.deepEqual(userThemeNames().sort(), ['brand', 'plain']);
    process.env.VIDEO_THEME = 'plain';
    assert.equal(loadProject('mine').theme.font.family, 'Georgia', 'a theme of yours can be chosen with --theme too');
  } finally { delete process.env.VIDEO_THEME; delete process.env.VIDEO_SOURCE; rmSync(dir, {recursive: true, force: true}); }
});

test('a broken theme file names the file and the problem, and without a repository only the built-in themes exist', () => {
  const dir = userRepo();
  mkdirSync(join(dir, '.kinhin/videos/themes'), {recursive: true});
  writeFileSync(join(dir, '.kinhin/videos/themes/oops.json'), JSON.stringify({colors: {ink: 'red'}}));
  process.env.VIDEO_SOURCE = dir;
  try {
    assert.throws(() => loadProject('short'), /themes[\s\S]*theme "oops"[\s\S]*font\.family/);
  } finally { delete process.env.VIDEO_SOURCE; rmSync(dir, {recursive: true, force: true}); }
  assert.deepEqual(userThemeNames(), []);
  assert.ok('paper' in loadThemes());
});
