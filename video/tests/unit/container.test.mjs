import assert from 'node:assert/strict';
import {accessSync, constants, readFileSync} from 'node:fs';
import {join} from 'node:path';
import {test} from 'node:test';
import {root} from '../helpers.mjs';

const read = (f) => readFileSync(join(root, f), 'utf8');

test('the image is self-contained: it carries the suite and an entry point that builds a mounted repository', () => {
  const containerfile = read('Dockerfile');
  assert.match(containerfile, /^COPY \. \/work$/m, 'the suite is copied in');
  assert.ok(containerfile.lastIndexOf('COPY . /work') > containerfile.indexOf('npm ci'), 'after the dependency layers, so editing the suite keeps them cached');
  accessSync(join(root, 'scripts/container-build.sh'), constants.X_OK);
  const entry = read('scripts/container-build.sh');
  assert.match(entry, /VIDEO_SOURCE=\/project/);
  assert.match(entry, /exec scripts\/build\.sh "\$@"/);
});

test('the build context leaves out what must not be baked in', () => {
  const ignored = read('.dockerignore').split('\n');
  for (const entry of ['node_modules', 'raw', 'out', '.venv-tts', '.generated']) assert.ok(ignored.includes(entry), entry);
});
