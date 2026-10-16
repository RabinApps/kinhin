import assert from 'node:assert/strict';
import {existsSync, mkdirSync, rmSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {test} from 'node:test';
import {listAdapters, loadAdapter, resolveClip, terminalVariant} from '../../scripts/adapter.mjs';
import {root} from '../helpers.mjs';

test('the kinhin and template adapters exist and name their clips', () => {
  assert.ok(listAdapters().includes('kinhin') && listAdapters().includes('template'));
  const k = loadAdapter('kinhin').manifest;
  assert.equal(k.clips.app.kind, 'app');
  assert.equal(k.clips.install.kind, 'terminal');
  const t = loadAdapter('template').manifest;
  assert.deepEqual(Object.keys(t.clips).sort(), ['app', 'demo', 'site']);
  assert.deepEqual(['app', 'terminal', 'browser'], [t.clips.app.kind, t.clips.demo.kind, t.clips.site.kind]);
});

test('an unknown adapter lists the ones that exist', () => {
  assert.throws(() => loadAdapter('nope'), /no adapter "nope".*kinhin/);
});

test('terminal variants: light or dark, landscape or portrait', () => {
  assert.equal(terminalVariant({}), '');
  assert.equal(terminalVariant({dark: true}), '-dark');
  assert.equal(terminalVariant({narrow: true}), '-portrait');
  assert.equal(terminalVariant({dark: true, narrow: true}), '-dark-portrait');
});

test('reference clips resolve for every variant of every committed terminal clip', () => {
  for (const [name, clip] of [['kinhin', 'install'], ['template', 'demo']]) {
    const a = loadAdapter(name);
    for (const [dark, narrow] of [[false, false], [true, false], [false, true], [true, true]]) {
      const r = resolveClip(a, clip, {dark, narrow});
      assert.ok(r, `${name}/${clip} dark=${dark} narrow=${narrow}`);
      assert.equal(r.note, null, 'the exact variant is committed, so no fallback note');
    }
  }
});

test('your own recording wins over the reference, and a missing variant falls back with a note', () => {
  const a = loadAdapter('template');
  const raw = join(root, 'raw', 'template');
  const marker = join(raw, 'demo-dark.mp4');
  const existed = existsSync(marker);
  mkdirSync(raw, {recursive: true});
  writeFileSync(marker, 'x');
  try {
    assert.equal(resolveClip(a, 'demo', {dark: true}).file, marker, 'raw beats reference');
  } finally {
    if (!existed) rmSync(marker, {force: true});
  }
  // An adapter whose only terminal clip is the plain one falls back to it.
  const fake = {name: 't', dir: root, manifest: {clips: {x: {kind: 'terminal'}}}, rawDir: join(root, 'raw', '__none__'), referenceDir: join(root, 'adapters', 'kinhin', 'reference')};
  fake.manifest.clips.install = fake.manifest.clips.x;
  const r = resolveClip(fake, 'install', {dark: true, narrow: true});
  assert.ok(r.file.endsWith('install-dark-portrait.mp4'));
  assert.equal(resolveClip(fake, 'nothing'), null);
});

test('the app clip metadata says when the story starts', () => {
  const r = resolveClip(loadAdapter('kinhin'), 'app');
  assert.ok(r.meta, 'app.json is committed next to the reference clip');
});
