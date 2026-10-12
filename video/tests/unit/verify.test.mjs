import assert from 'node:assert/strict';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {after, before, test} from 'node:test';
import {parseSrt, verifyVideo} from '../../scripts/verify.mjs';
import {has, makeFixtureVideo} from '../helpers.mjs';

const ffmpeg = has('ffmpeg') && has('ffprobe');
let dir;
before(() => { dir = mkdtempSync(join(tmpdir(), 'verify-')); });
after(() => rmSync(dir, {recursive: true, force: true}));

const timeline = (over = {}) => ({total: 3, format: {width: 320, height: 180}, scenes: {a: {cues: [{}]}}, ...over});

test('parseSrt reads cues and rejects broken blocks', () => {
  const cues = parseSrt('1\n00:00:01,000 --> 00:00:02,500\nhello\nworld\n\n2\n00:01:00,000 --> 00:01:01,000\nagain\n');
  assert.deepEqual(cues.map((c) => [c.n, c.start, c.end, c.text]), [[1, 1, 2.5, 'hello world'], [2, 60, 61, 'again']]);
  assert.deepEqual(parseSrt(''), []);
  assert.throws(() => parseSrt('1\nnot a time\ntext'), /bad caption block/);
});

test('a good video passes every check', {skip: !ffmpeg && 'needs ffmpeg'}, () => {
  const f = makeFixtureVideo(dir, 'good');
  const {failures, facts} = verifyVideo(f, {timeline: timeline(), maxMB: 5, maxSeconds: 10, loudnessTarget: -48, loudnessTolerance: 6});
  assert.deepEqual(failures, []);
  assert.equal(facts.width, 320);
  assert.equal(facts.captions, 1);
});

test('each kind of problem is reported on its own', {skip: !ffmpeg && 'needs ffmpeg'}, () => {
  const lenient = {loudnessTarget: -48, loudnessTolerance: 6};
  assert.match(verifyVideo(makeFixtureVideo(dir, 'size'), {timeline: timeline({format: {width: 640, height: 360}}), ...lenient}).failures.join(), /frame is 320x180, expected 640x360/);
  assert.match(verifyVideo(makeFixtureVideo(dir, 'dur'), {timeline: timeline({total: 9}), ...lenient}).failures.join(), /not within 1 s of the timeline/);
  assert.match(verifyVideo(makeFixtureVideo(dir, 'long'), {maxSeconds: 2, ...lenient}).failures.join(), /exceeds the 2 s budget/);
  assert.match(verifyVideo(makeFixtureVideo(dir, 'big', {width: 1280, height: 720}), {maxMB: 0.001, ...lenient}).failures.join(), /exceeds the 0.001 MB budget/);
  assert.match(verifyVideo(makeFixtureVideo(dir, 'mute', {silent: true})).failures.join(), /no audio stream/);
  assert.match(verifyVideo(makeFixtureVideo(dir, 'loud', {loud: true}), {loudnessTarget: -40, loudnessTolerance: 1}).failures.join(), /loudness .* LUFS is more than 1 LU from -40/);
  assert.match(verifyVideo(makeFixtureVideo(dir, 'dark', {black: true, seconds: 4}), lenient).failures.join(), /black frames/);
  assert.match(verifyVideo(makeFixtureVideo(dir, 'nosrt', {srt: false}), lenient).failures.join(), /no caption file/);
  assert.match(verifyVideo(makeFixtureVideo(dir, 'nocap'), {timeline: timeline({scenes: {a: {cues: [{}, {}, {}]}}}), ...lenient}).failures.join(), /1 captions for 3 cues/);
  assert.match(verifyVideo(makeFixtureVideo(dir, 'noposter', {poster: false}), lenient).failures.join(), /no poster/);
  assert.match(verifyVideo(join(dir, 'missing.mp4')).failures.join(), /does not exist/);
});

test('a flat poster is reported as blank', {skip: !ffmpeg && 'needs ffmpeg'}, async () => {
  const {execFileSync} = await import('node:child_process');
  const f = makeFixtureVideo(dir, 'flat');
  execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=white:s=320x180:d=1', '-frames:v', '1', join(dir, 'flat-poster.png')]);
  assert.match(verifyVideo(f, {loudnessTarget: -48, loudnessTolerance: 6}).failures.join(), /the poster is blank/);
});

test('a sparse slide (a little text on a plain backdrop) is a valid poster, a flat frame is not', {skip: !ffmpeg && 'needs ffmpeg'}, async () => {
  const {execFileSync} = await import('node:child_process');
  const {edgeFraction, notBlank} = await import('../../scripts/verify.mjs');
  const sparse = join(dir, 'sparse.png');
  // Two short bars on a soft gradient: about as little as a one-sentence slide shows.
  execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'gradients=s=1280x720:c0=0xffffff:c1=0xe6ebf5:speed=0.00001:d=1', '-vf', 'drawbox=x=420:y=330:w=440:h=14:color=black:t=fill,drawbox=x=520:y=380:w=240:h=8:color=gray:t=fill', '-frames:v', '1', sparse]);
  const flat = join(dir, 'flat2.png');
  execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'gradients=s=1280x720:c0=0xffffff:c1=0xe6ebf5:speed=0.00001:d=1', '-frames:v', '1', flat]);
  assert.ok(notBlank(sparse), `edges: ${edgeFraction(sparse)}`);
  assert.ok(!notBlank(flat), 'the backdrop alone has no edges');
});
