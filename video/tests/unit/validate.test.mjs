import assert from 'node:assert/strict';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {validateVideo} from '../../scripts/validate.mjs';

// A repository with an adapter ("acme": an app clip and a terminal clip, both recorded) and the videos a test writes.
function repo(files) {
  const dir = mkdtempSync(join(tmpdir(), 'kinhin-validate-'));
  const adapter = join(dir, '.kinhin', 'videos', 'adapters', 'acme');
  mkdirSync(join(adapter, 'reference'), {recursive: true});
  writeFileSync(join(adapter, 'adapter.yml'), 'name: acme\nclips:\n  app: {kind: app}\n  demo: {kind: terminal}\n');
  writeFileSync(join(adapter, 'reference', 'app.mp4'), 'x');
  writeFileSync(join(adapter, 'reference', 'demo.mp4'), 'x');
  for (const [name, text] of Object.entries(files)) {
    const file = join(dir, '.kinhin', 'videos', name);
    mkdirSync(join(file, '..'), {recursive: true});
    writeFileSync(file, text);
  }
  return dir;
}

// Runs validateVideo with VIDEO_SOURCE set to the repository, then restores the environment.
function check(dir, name) {
  const before = process.env.VIDEO_SOURCE;
  process.env.VIDEO_SOURCE = dir;
  try {
    return validateVideo(name);
  } finally {
    if (before === undefined) delete process.env.VIDEO_SOURCE;
    else process.env.VIDEO_SOURCE = before;
  }
}

const good = `name: Good
adapter: acme
scenes:
  - {id: a, type: title, props: {title: Acme, subtitle: Ship}, narration: Hello.}
  - {id: b, type: device, props: {clip: app}, narration: This is the app.}
  - {id: c, type: terminal, props: {clip: demo}, narration: And the command line.}
`;

test('a video whose clips, adapter and structure are right has no problems', () => {
  const dir = repo({'good.yml': good});
  assert.deepEqual(check(dir, 'good').problems, []);
  assert.equal(check(dir, 'good').adapter, 'acme');
});

test('a structural problem is named in the project-file wording, and nothing else runs', () => {
  const dir = repo({'bad.yml': 'name: Bad\nscenes:\n  - {id: a, type: titel, props: {}, narration: Hi.}\n'});
  const {problems} = check(dir, 'bad');
  assert.equal(problems.length, 1);
  assert.match(problems[0], /unknown type "titel"/);
});

test('a clip the adapter does not declare, a missing clip and a clip without an adapter are each named', () => {
  const dir = repo({
    'missing.yml': 'name: M\nadapter: acme\nscenes:\n  - {id: a, type: device, props: {clip: nope}, narration: Hi.}\n  - {id: b, type: terminal, props: {}, narration: Hi.}\n',
    'noadapter.yml': 'name: N\nscenes:\n  - {id: a, type: device, props: {clip: app}, narration: Hi.}\n',
  });
  const missing = check(dir, 'missing').problems.join('\n');
  assert.match(missing, /scene "a": no clip "nope" in the acme adapter/);
  assert.match(missing, /scene "b": a terminal scene needs props.clip/);
  assert.match(check(dir, 'noadapter').problems.join('\n'), /clip "app" needs an "adapter"/);
});

test('an adapter that does not exist is reported, not silently ignored', () => {
  const dir = repo({'ghost.yml': 'name: G\nadapter: ghost\nscenes:\n  - {id: a, type: title, props: {title: T}, narration: Hi.}\n'});
  assert.match(check(dir, 'ghost').problems.join('\n'), /no adapter "ghost"/);
});

test('a recording missing for this look is named with where to put it', () => {
  const dir = repo({'norec.yml': 'name: R\nadapter: acme\nscenes:\n  - {id: a, type: device, props: {clip: app}, narration: Hi.}\n'});
  const adapter = join(dir, '.kinhin', 'videos', 'adapters', 'acme', 'reference', 'app.mp4');
  rmSync(adapter);
  assert.match(check(dir, 'norec').problems.join('\n'), /no recording for clip "app"/);
});

test('a local music file must be in the repository', () => {
  const dir = repo({
    'music.yml': `name: M\nmusic: {track: audio/missing.mp3}\nscenes:\n  - {id: a, type: title, props: {title: T}, narration: Hi.}\n`,
  });
  assert.match(check(dir, 'music').problems.join('\n'), /music track "audio\/missing.mp3" is not in your repository/);
  mkdirSync(join(dir, 'audio'));
  writeFileSync(join(dir, 'audio', 'missing.mp3'), 'x');
  assert.deepEqual(check(dir, 'music').problems, []);
});

test('the adapter claims are applied to the video text', () => {
  const dir = repo({
    'claims.yml': `name: C\nadapter: acme\nscenes:\n  - {id: a, type: title, props: {title: T}, narration: The fastest CI.}\n`,
  });
  writeFileSync(join(dir, '.kinhin', 'videos', 'adapters', 'acme', 'claims.json'), JSON.stringify({forbidden: ['fastest']}));
  assert.match(check(dir, 'claims').problems.join('\n'), /avoid "fastest"/);
});
