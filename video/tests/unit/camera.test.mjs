import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {after, before, test} from 'node:test';
import {applyCamera, cameraGraph, cameraSeries, cursorSeries, expression, probeSize, smooth, valueAt, wantsCamera} from '../../scripts/camera.mjs';
import {has} from '../helpers.mjs';

test('smoothstep eases in and out', () => {
  assert.equal(smooth(0), 0);
  assert.equal(smooth(1), 1);
  assert.equal(smooth(0.5), 0.5);
  assert.ok(smooth(0.1) < 0.1 && smooth(0.9) > 0.9, 'slow at both ends');
});

const near = (actual, expected, message) => assert.ok(Math.abs(actual - expected) < 1e-9, `${message ?? ''} expected ${expected}, got ${actual}`);

test('the camera starts at zoom 1, centred, moves at each keyframe and holds between them', () => {
  const s = cameraSeries([{at: 2, zoom: 2, to: [0.8, 0.2]}, {at: 6, zoom: 1}]);
  assert.equal(valueAt(1, s.zoom, 0), 1);
  assert.equal(valueAt(1, s.zoom, 1.99), 1);
  near(valueAt(1, s.zoom, 2 + 0.4), 1.5, 'halfway through the 0.8 s move');
  assert.equal(valueAt(1, s.zoom, 4), 2, 'held');
  near(valueAt(1, s.zoom, 6.4), 1.5, 'the second keyframe starts its own move');
  assert.equal(valueAt(1, s.zoom, 9), 1);
  near(valueAt(0.5, s.x, 4), 0.8);
  near(valueAt(0.5, s.x, 9), 0.8, 'a keyframe with no `to` keeps the centre');
  near(valueAt(0.5, s.y, 4), 0.2);
});

test('a move never runs past the next keyframe, and `move` sets its length', () => {
  const s = cameraSeries([{at: 1, zoom: 2, move: 3}, {at: 1.5, zoom: 3}]);
  assert.equal(s.zoom[0].b, 1.5, 'cut short by the next keyframe');
  assert.equal(cameraSeries([{at: 1, zoom: 2, move: 2}]).zoom[0].b, 3);
  const unsorted = cameraSeries([{at: 5, zoom: 1}, {at: 1, zoom: 2}]);
  assert.equal(unsorted.zoom[0].a, 1, 'keyframes are used in time order');
});

test('the cursor reaches each point at its time, setting off at most a second before', () => {
  const c = cursorSeries([{at: 1, to: [0.1, 0.1]}, {at: 5, to: [0.9, 0.5]}, {at: 5.5, to: [0.9, 0.9], click: true}]);
  assert.equal(valueAt(0.1, c.x, 3.9), 0.1, 'still at the first point');
  near(valueAt(0.1, c.x, 5), 0.9);
  near(valueAt(0.5, c.y, 5.25), 0.7, 'halfway to the third point (0.5 s trip)');
  assert.equal(c.start.at, 1);
});

test('the ffmpeg expression has one nested if per piece and ends on the held value', () => {
  const s = cameraSeries([{at: 2, zoom: 2}, {at: 6, zoom: 1}]);
  const e = expression(1, s.zoom);
  assert.equal(e.match(/if\(lt/g).length, 4);
  assert.match(e, /^if\(lt\(t,2\),1,if\(lt\(t,2\.8\),1\+\(1\)\*/);
  assert.ok(e.endsWith('1' + ')'.repeat(4)));
  assert.equal(expression(0.5, []), '0.5', 'no moves, no expression');
});

test('wantsCamera is true for any of the three props', () => {
  assert.equal(wantsCamera({clip: 'app'}), false);
  assert.equal(wantsCamera(undefined), false);
  for (const k of ['camera', 'focus', 'cursor']) assert.equal(wantsCamera({[k]: []}), true);
});

test('the graph has a layer for each thing asked for, and nothing for what was not', () => {
  const base = {width: 1600, height: 1256, length: 8};
  const plain = cameraGraph({...base, props: {}});
  assert.ok(!/scale=w=|overlay|geq/.test(plain), 'no camera work, just the clip normalised');
  const all = cameraGraph({...base, props: {camera: [{at: 1, zoom: 2}], focus: {from: 1, to: 2, box: [0.1, 0.1, 0.4, 0.4]}, cursor: [{at: 1, to: [0.2, 0.2]}, {at: 2, to: [0.3, 0.3], click: true}]}});
  for (const piece of ['eval=frame', 'crop=1600:1256', '[s0]', '[dot]', '[ring0]', 'format=yuv420p[out]']) assert.ok(all.includes(piece), piece);
  assert.ok(!cameraGraph({...base, props: {cursor: [{at: 1, to: [0.5, 0.5]}]}}).includes('[ring0]'), 'a ring only for a click');
  assert.ok(cameraGraph({...base, cover: '0x2b2b2b', props: {}}).includes('drawbox=x=14:y=6:w=130:h=48:color=0x2b2b2b'), 'the laptop frame covers the toolbar buttons first');
  assert.ok(!plain.includes('drawbox'));
});

const ffmpeg = has('ffmpeg') && has('ffprobe');
let dir;
before(() => { dir = mkdtempSync(join(tmpdir(), 'camera-')); });
after(() => rmSync(dir, {recursive: true, force: true}));

// The mean red and blue of the left and right halves of a frame (as {r, b}), to tell which part of the picture the camera shows.
const halves = (file, at) => {
  const mean = (crop) => {
    const out = execFileSync('ffmpeg', ['-nostdin', '-loglevel', 'error', '-ss', String(at), '-i', file, '-frames:v', '1', '-vf', `${crop},scale=1:1:flags=area,format=rgb24`, '-f', 'rawvideo', '-']);
    return {r: out[0], b: out[2]};
  };
  return {left: mean('crop=iw/2:ih:0:0'), right: mean('crop=iw/2:ih:iw/2:0')};
};

test('a zoom shows the part of the recording it is centred on, at the original size, for exactly the scene length', {skip: !ffmpeg && 'needs ffmpeg'}, () => {
  // Left half red, right half blue, 4 s long, 320x200.
  const src = join(dir, 'src.mp4');
  execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=red:s=160x200:r=30:d=4', '-f', 'lavfi', '-i', 'color=c=blue:s=160x200:r=30:d=4', '-filter_complex', '[0][1]hstack,format=yuv420p', '-c:v', 'libx264', src]);
  assert.deepEqual(probeSize(src), {width: 320, height: 200});
  const out = join(dir, 'out.mp4');
  const quiet = console.log;
  console.log = () => {};
  try {
    applyCamera({clip: src, out, length: 3, props: {camera: [{at: 0.5, zoom: 2, to: [0.85, 0.5], move: 0.5}]}});
  } finally {
    console.log = quiet;
  }
  assert.deepEqual(probeSize(out), {width: 320, height: 200}, 'the same size, so the frame is unaffected');
  const seconds = Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', out]).toString());
  assert.ok(Math.abs(seconds - 3) < 0.1, `3 s, got ${seconds}`);
  const start = halves(out, 0.2);
  assert.ok(start.left.r > start.left.b && start.right.b > start.right.r, 'before the move the picture is as recorded: red, then blue');
  const zoomed = halves(out, 2);
  assert.ok(zoomed.left.b > zoomed.left.r && zoomed.right.b > zoomed.right.r, 'zoomed on the blue side, both halves of the frame are blue');
});

test('a clip that is shorter than the scene holds its last frame, and speed plays it faster', {skip: !ffmpeg && 'needs ffmpeg'}, () => {
  const src = join(dir, 'short.mp4');
  execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=160x100:r=30:d=1', '-pix_fmt', 'yuv420p', src]);
  const out = join(dir, 'held.mp4');
  const quiet = console.log;
  console.log = () => {};
  try {
    applyCamera({clip: src, out, length: 2, props: {cursor: [{at: 0.2, to: [0.5, 0.5]}]}});
    applyCamera({clip: src, out: join(dir, 'fast.mp4'), length: 0.5, speed: 2, props: {cursor: [{at: 0.1, to: [0.5, 0.5]}]}});
  } finally {
    console.log = quiet;
  }
  const length = (f) => Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', f]).toString());
  assert.ok(Math.abs(length(out) - 2) < 0.1);
  assert.ok(Math.abs(length(join(dir, 'fast.mp4')) - 0.5) < 0.1);
});
