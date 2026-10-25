import assert from 'node:assert/strict';
import {test} from 'node:test';
import {join} from 'node:path';
import {readFileSync} from 'node:fs';
import {resolveCaptions, resolveTheme, validateCaptions, buildThemes} from '../../shared/resolve.mjs';
import {root} from '../helpers.mjs';

const themes = buildThemes(Object.fromEntries(['paper'].map((n) => [n, JSON.parse(readFileSync(join(root, 'themes', `${n}.json`), 'utf8'))])));
const theme = resolveTheme(themes, 'paper');
const caps = (over = {}) => resolveCaptions({theme, ...over});

test('a list of formats burns captions in those formats only', () => {
  const adapter = {captions: {burn: ['9:16', '1:1']}};
  assert.equal(caps({adapter, format: '9:16'}).burn, true, 'vertical is burned');
  assert.equal(caps({adapter, format: '1:1'}).burn, true, 'square is burned');
  assert.equal(caps({adapter, format: '16:9'}).burn, false, 'landscape stays clean');
  assert.equal(caps({adapter, format: '4:5'}).burn, false, 'a format not in the list stays clean');
});

test('a boolean still works for every format, and the default burns', () => {
  assert.equal(caps({adapter: {captions: {burn: false}}, format: '9:16'}).burn, false);
  assert.equal(caps({format: '16:9'}).burn, true);
});

test('the project can give its own list, and the command line still overrides it', () => {
  const adapter = {captions: {burn: ['9:16']}};
  assert.equal(caps({adapter, project: {captions: {burn: ['16:9']}}, format: '16:9'}).burn, true, 'the project list wins');
  assert.equal(caps({adapter, format: '9:16', env: {VIDEO_CAPTIONS: 'off'}}).burn, false, '--captions off wins');
  assert.equal(caps({adapter, format: '16:9', env: {VIDEO_CAPTIONS: 'on'}}).burn, true, '--captions on wins');
});

test('a list must name real formats', () => {
  assert.deepEqual(validateCaptions({burn: ['9:16', '1:1']}), []);
  assert.equal(validateCaptions({burn: ['vertical']}).length, 1);
  assert.equal(validateCaptions({burn: 'yes'}).length, 1);
});
