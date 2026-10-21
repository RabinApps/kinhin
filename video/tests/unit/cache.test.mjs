import assert from 'node:assert/strict';
import {existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {after, before, test} from 'node:test';
import {frameKey, hashFile, hashFileOnce, prune, pruneFolders, readJson, sha, voiceKey, withCache, writeJson} from '../../scripts/cache.mjs';

let dir;
before(() => { dir = mkdtempSync(join(tmpdir(), 'cache-')); });
after(() => rmSync(dir, {recursive: true, force: true}));

test('sha is the same for the same value and different for any change', () => {
  assert.equal(sha({a: 1, b: [1, 2]}), sha({a: 1, b: [1, 2]}));
  assert.notEqual(sha({a: 1}), sha({a: 2}));
  assert.equal(sha('x'), sha('x'));
  assert.match(sha('x'), /^[0-9a-f]{64}$/);
});

test('hashFile hashes the bytes, however large, and notices a change', () => {
  const file = join(dir, 'clip.bin');
  writeFileSync(file, Buffer.alloc(3 * (1 << 20) + 5, 7)); // more than two read chunks
  const before = hashFile(file);
  assert.equal(before, hashFile(file));
  writeFileSync(file, Buffer.concat([Buffer.alloc(3 * (1 << 20) + 4, 7), Buffer.from([8])]));
  assert.notEqual(hashFile(file), before);
  writeFileSync(join(dir, 'empty'), '');
  assert.equal(hashFile(join(dir, 'empty')), sha(''));
});

test('a JSON file that is not there reads as the fallback', () => {
  const file = join(dir, 'c.json');
  assert.deepEqual(readJson(file), {});
  writeJson(file, {a: 1});
  assert.deepEqual(readJson(file), {a: 1});
  assert.ok(readFileSync(file, 'utf8').endsWith('}\n'));
});

test('a cue sounds different with a different text, voice, speed, engine or model, and not otherwise', () => {
  const base = {engine: 'kokoro', model: 'm1', voice: 'af_heart', speed: 1, text: 'Hello there.'};
  assert.equal(voiceKey(base), voiceKey({...base}));
  for (const change of [{text: 'Hello there'}, {voice: 'am_michael'}, {speed: 1.1}, {engine: 'say'}, {model: 'm2'}]) assert.notEqual(voiceKey({...base, ...change}), voiceKey(base), JSON.stringify(change));
});

test('a framed clip is framed again when anything that shapes it changes', () => {
  const base = {type: 'device', props: {clip: 'app', speed: 2}, targets: [null], length: 11, look: 'VIDEO_W=1920', files: [{file: 'aa', meta: null}], code: 'cc'};
  assert.equal(frameKey(base), frameKey(JSON.parse(JSON.stringify(base))));
  const changes = [
    {type: 'terminal'}, {props: {clip: 'app', speed: 3}}, {targets: [{fleet: [0, 0, 1, 1]}]}, {length: 11.5}, {look: 'VIDEO_W=1080'},
    {files: [{file: 'bb', meta: null}]}, {files: [{file: 'aa', meta: '{"demoStartsAt": 4}'}]}, {code: 'dd'},
  ];
  for (const change of changes) assert.notEqual(frameKey({...base, ...change}), frameKey(base), JSON.stringify(change));
});

// A cue store where "speaking" a job writes its text, so a test can tell a hit from a miss.
const speak = (spoken) => async (todo) => todo.map((job) => { writeFileSync(job.out, job.text); spoken.push(job.text); return job.text.length; });

test('only the jobs that are not cached are rendered, and the rest are copied from the cache', async () => {
  const store = join(dir, 'voice-cache');
  const outs = join(dir, 'voice');
  mkdirSync(outs, {recursive: true});
  const jobs = (texts) => texts.map((text, i) => ({text, out: join(outs, `${i}.m4a`)}));
  const options = (spoken, force = false) => ({dir: store, force, key: (job) => sha(job.text), render: speak(spoken), seconds: (file) => readFileSync(file, 'utf8').length + 100});

  const first = [];
  const a = jobs(['one', 'two']);
  assert.deepEqual(await withCache(a, options(first)), {hits: 0, misses: 2});
  assert.deepEqual(first, ['one', 'two']);
  assert.deepEqual(a.map((j) => j.seconds), [3, 3], 'a rendered job gets the duration render() returned');

  const second = [];
  const b = jobs(['one', 'three', 'two']);
  assert.deepEqual(await withCache(b, options(second)), {hits: 2, misses: 1});
  assert.deepEqual(second, ['three'], 'only the new sentence is spoken');
  assert.deepEqual(b.map((j) => readFileSync(j.out, 'utf8')), ['one', 'three', 'two'], 'every job has its audio, in its own place');
  assert.deepEqual(b.map((j) => j.seconds), [103, 5, 103], 'a hit is measured, a miss is the rendered duration');

  const third = [];
  assert.deepEqual(await withCache(jobs(['one']), options(third, true)), {hits: 0, misses: 1}, 'force speaks it again');
  assert.deepEqual(third, ['one']);

  const none = [];
  assert.deepEqual(await withCache([], options(none)), {hits: 0, misses: 0});
  assert.deepEqual(none, [], 'nothing to speak, nothing rendered');
});

test('prune removes what has not been used for a while and keeps the rest', () => {
  const store = join(dir, 'prune');
  mkdirSync(store, {recursive: true});
  writeFileSync(join(store, 'old.m4a'), 'x');
  writeFileSync(join(store, 'new.m4a'), 'x');
  const longAgo = new Date(Date.now() - 40 * 86400000);
  utimesSync(join(store, 'old.m4a'), longAgo, longAgo);
  assert.equal(prune(store, 30), 1);
  assert.ok(!existsSync(join(store, 'old.m4a')) && existsSync(join(store, 'new.m4a')));
  assert.equal(prune(join(dir, 'absent')), 0, 'no folder, nothing to do');
  assert.ok(statSync(join(store, 'new.m4a')).isFile());
});

test('a recording is hashed once, and again when its size or time changes', () => {
  const file = join(dir, 'recording.mov');
  writeFileSync(file, 'one');
  const store = {};
  const first = hashFileOnce(file, store);
  assert.equal(first, sha('one'));
  store[file].sha = 'remembered'; // what the store says is used while the file looks the same
  assert.equal(hashFileOnce(file, store), 'remembered');
  writeFileSync(file, 'three'); // a different size
  assert.equal(hashFileOnce(file, store), sha('three'));
  const t = new Date(Date.now() + 5000);
  utimesSync(file, t, t); // the same bytes, a new time: read again
  store[file].sha = 'stale';
  assert.equal(hashFileOnce(file, store), sha('three'));
});

test('pruneFolders clears old files from each project folder and removes the folders left empty', () => {
  const frames = join(dir, 'frames');
  for (const project of ['old', 'mixed']) mkdirSync(join(frames, project), {recursive: true});
  writeFileSync(join(frames, 'old', 'a.mp4'), 'x');
  writeFileSync(join(frames, 'mixed', 'a.mp4'), 'x');
  writeFileSync(join(frames, 'mixed', 'b.mp4'), 'x');
  const longAgo = new Date(Date.now() - 90 * 86400000);
  for (const f of ['old/a.mp4', 'mixed/a.mp4']) utimesSync(join(frames, f), longAgo, longAgo);
  assert.equal(pruneFolders(frames, 60), 2);
  assert.ok(!existsSync(join(frames, 'old')), 'a folder with nothing left goes');
  assert.ok(existsSync(join(frames, 'mixed', 'b.mp4')) && !existsSync(join(frames, 'mixed', 'a.mp4')));
  assert.equal(pruneFolders(join(dir, 'nothing-here')), 0);
});
