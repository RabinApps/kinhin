import assert from 'node:assert/strict';
import {accessSync, constants, readFileSync} from 'node:fs';
import {join} from 'node:path';
import {test} from 'node:test';
import {repo, root} from '../helpers.mjs';

const read = (f) => readFileSync(join(root, f), 'utf8');

test('the image is self-contained: it carries the suite and an entry point that builds a mounted repository', () => {
  const containerfile = read('Dockerfile');
  assert.match(containerfile, /^COPY \. \/work$/m, 'the suite is copied in');
  assert.ok(containerfile.lastIndexOf('COPY . /work') > containerfile.indexOf('npm ci'), 'after the dependency layers, so editing the suite keeps them cached');
  accessSync(join(root, 'scripts/container-build.sh'), constants.X_OK);
  const entry = read('scripts/container-build.sh');
  assert.match(entry, /VIDEO_SOURCE=\/project/);
  assert.match(entry, /scripts\/build\.sh "\$@"/);
  assert.match(entry, /rm -rf out\/\.work/, "the scratch folder is not left in the user's out directory");
});

test('the build context leaves out what must not be baked in', () => {
  const ignored = read('.dockerignore').split('\n');
  for (const entry of ['node_modules', 'raw', 'out', '.venv-tts', '.generated']) assert.ok(ignored.includes(entry), entry);
});

test('the base image is pinned by digest and its Playwright version matches playwright-core', () => {
  const from = read('Dockerfile').match(/^FROM (\S+)$/m)?.[1] ?? '';
  assert.match(from, /^mcr\.microsoft\.com\/playwright:v\d+\.\d+\.\d+-[a-z]+@sha256:[0-9a-f]{64}$/, `pin the base image by digest, got "${from}"`);
  const tag = from.match(/:v(\d+\.\d+\.\d+)-/)[1];
  const core = JSON.parse(read('package.json')).devDependencies['playwright-core'];
  assert.equal(core, tag, 'playwright-core in package.json must be the Playwright version of the base image (bump both together)');
});

test('Dependabot keeps the image and the video npm packages fresh', () => {
  const config = readFileSync(join(repo, '.github/dependabot.yml'), 'utf8');
  const entry = (ecosystem) => config.split(/\n  - package-ecosystem: /).find((block) => block.startsWith(ecosystem));
  for (const ecosystem of ['docker', 'npm']) {
    const block = entry(ecosystem);
    assert.ok(block, `a ${ecosystem} entry`);
    assert.match(block, /directory: \/video\n/, `${ecosystem} watches video/`);
    assert.match(block, /interval: weekly/);
  }
  // Dependabot's docker ecosystem only reads files named Dockerfile.
  accessSync(join(root, 'Dockerfile'), constants.R_OK);
});
