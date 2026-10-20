import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {after, before, test} from 'node:test';
import {applyCamera, cameraGraph, wantsCamera} from '../../scripts/camera.mjs';
import {clipMinLength, outputLength, sourceSeconds, speedFilter, speedPieces} from '../../scripts/speed.mjs';
import {has} from '../helpers.mjs';

const near = (actual, expected, message, tolerance = 1e-6) => assert.ok(Math.abs(actual - expected) < tolerance, `${message ?? ''} expected ${expected}, got ${actual}`);

test('segments without a ramp are plain pieces of the recording, the last one open', () => {
  const pieces = speedPieces([{until: 20, speed: 8}, {until: 30, speed: 1}, {speed: 4}], 0);
  assert.deepEqual(pieces, [{from: 0, to: 20, speed: 8}, {from: 20, to: 30, speed: 1}, {from: 30, to: Infinity, speed: 4}]);
  near(outputLength([{until: 20, speed: 8}, {until: 30, speed: 1}, {speed: 4}], 0), 20 / 8 + 10, 'the closed pieces, in output seconds');
});

test('a speed change eases over `ramp` output seconds, through speeds between the two', () => {
  const pieces = speedPieces([{until: 10, speed: 8}, {speed: 1}], 0.6);
  const ease = pieces.slice(1, -1);
  assert.equal(ease.length, 6);
  near(ease.reduce((sum, p) => sum + (p.to - p.from) / p.speed, 0), 0.6, 'the ease lasts the ramp');
  assert.ok(ease.every((p, i) => p.speed < (i ? ease[i - 1].speed : 8) && p.speed > 1), 'slowing down, never past either end');
  assert.equal(pieces[0].to, 10, 'the first speed holds until `until`');
  assert.equal(pieces[1].from, 10, 'and the ease starts there');
  near(pieces[pieces.length - 1].from, ease[5].to, 'the next segment carries on where the ease left off');
  near(outputLength([{until: 10, speed: 8}, {speed: 1}], 0.6), 10 / 8 + 0.6);
});

test('no ease between two segments at the same speed, and a short segment can be eaten by the ease', () => {
  assert.equal(speedPieces([{until: 5, speed: 2}, {speed: 2}], 0.4).length, 2);
  const eaten = speedPieces([{until: 5, speed: 1}, {until: 5.1, speed: 8}, {speed: 1}], 0.4);
  assert.ok(eaten.every((p) => p.to > p.from), 'no piece of zero or negative length');
});

test('the source seconds a scene uses: the closed pieces plus what the open one plays in the time left', () => {
  const segs = [{until: 8, speed: 4}, {speed: 1}];
  near(sourceSeconds(segs, 6, 0), 8 + 4, '2 s at 4x, then 4 s at 1x');
  near(sourceSeconds(segs, 1, 0), 8, 'a scene shorter than the closed pieces still plays them');
  near(sourceSeconds([{speed: 2}], 5), 10);
});

test('a speed list asks for its closed pieces\' length, a split panel adds its delay, a number asks for nothing', () => {
  near(clipMinLength({speed: [{until: 8, speed: 4}, {speed: 1}], ramp: 0}), 2);
  near(clipMinLength({speed: [{until: 8, speed: 4}, {speed: 1}], ramp: 0, delay: 1.5}), 3.5);
  assert.equal(clipMinLength({speed: 3}), 0);
  assert.equal(clipMinLength({clip: 'app'}), 0);
  assert.equal(clipMinLength(undefined), 0);
});

test('a speed list needs the camera pass, and the graph cuts, retimes and joins each piece', () => {
  assert.equal(wantsCamera({speed: [{speed: 2}]}), true);
  assert.equal(wantsCamera({speed: 2}), false, 'a constant speed is the laptop frame\'s own');
  const graph = speedFilter(speedPieces([{until: 4, speed: 2}, {speed: 1}], 0), 30);
  assert.equal(graph, '[0:v]split=2[p0][p1];[p0]trim=start=0:end=4,setpts=(PTS-STARTPTS)/2,fps=30[q0];[p1]trim=start=4,setpts=(PTS-STARTPTS)/1,fps=30[q1];[q0][q1]concat=n=2:v=1:a=0[sp]');
  assert.equal(speedFilter([{from: 0, to: Infinity, speed: 2}], 30), '[0:v]null[p0];[p0]trim=start=0,setpts=(PTS-STARTPTS)/2,fps=30[q0];[q0]null[sp]', 'one piece needs no split or concat');
  const full = cameraGraph({width: 160, height: 100, length: 6, props: {speed: [{until: 4, speed: 2}, {speed: 1}], ramp: 0}});
  assert.ok(full.startsWith('[0:v]split=2') && full.includes('[sp]fps=30,tpad') && !full.includes('setpts=(PTS-STARTPTS)/1,fps=30,tpad'));
});

const ffmpeg = has('ffmpeg') && has('ffprobe');
let dir;
before(() => { dir = mkdtempSync(join(tmpdir(), 'speed-')); });
after(() => rmSync(dir, {recursive: true, force: true}));

// A 20 s clip whose brightness is its own time: frame luma / 255 * 20 is the second of the recording it shows (a little off,
// through the video range), so a retimed copy can be checked against the source at known seconds.
const luma = (file, at) => execFileSync('ffmpeg', ['-nostdin', '-loglevel', 'error', '-ss', String(at), '-i', file, '-frames:v', '1', '-vf', 'scale=1:1:flags=area,format=gray', '-f', 'rawvideo', '-'])[0];

test('a ramped clip is exactly as long as the scene and shows the source at the speed asked for', {skip: !ffmpeg && 'needs ffmpeg'}, () => {
  const src = join(dir, 'src.mp4');
  execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', "nullsrc=s=160x100:r=30:d=20,format=yuv420p,geq=lum='255*T/20':cb=128:cr=128", '-c:v', 'libx264', '-crf', '12', '-g', '1', src]);
  const out = join(dir, 'out.mp4');
  const quiet = console.log;
  console.log = () => {};
  try {
    applyCamera({clip: src, out, length: 6, props: {speed: [{until: 8, speed: 4}, {speed: 1}], ramp: 0}});
  } finally {
    console.log = quiet;
  }
  const seconds = Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', out]).toString());
  near(seconds, 6, 'the scene\'s length', 0.1);
  // Output 1 s is source 4 s; output 3 s is source 8 + 1 = 9 s: compare with the source's own frames at those seconds.
  near(luma(out, 1), luma(src, 4), 'output 1 s shows source 4 s', 3);
  near(luma(out, 3), luma(src, 9), 'output 3 s shows source 9 s', 3);
  assert.ok(luma(src, 9) - luma(src, 4) > 20, 'the two seconds really look different');
});
