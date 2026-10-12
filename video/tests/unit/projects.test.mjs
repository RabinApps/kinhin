import assert from 'node:assert/strict';
import {existsSync} from 'node:fs';
import {join} from 'node:path';
import {test} from 'node:test';
import {loadAdapter, resolveClip} from '../../scripts/adapter.mjs';
import {loadProject, shellEnv} from '../../scripts/project.mjs';
import {projectNames, root, themeNames} from '../helpers.mjs';

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
  assert.throws(() => loadProject('does-not-exist'), /ENOENT|no such file/);
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
