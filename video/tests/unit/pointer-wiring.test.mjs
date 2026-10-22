import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {after, before, test} from 'node:test';
import {applyCamera, autoZoomSpec, pointerFileOf} from '../../scripts/camera.mjs';
import {cutPointerLog} from '../../scripts/pointer-log.mjs';
import {has, root} from '../helpers.mjs';

const reference = join(root, 'adapters/kinhin/reference/app.mp4');
const log = {
  samples: [{t: 0.5, x: 0.2, y: 0.2}, {t: 4, x: 0.3, y: 0.5}, {t: 9, x: 0.6, y: 0.6}],
  clicks: [{t: 5, x: 0.3, y: 0.5}, {t: 5.5, x: 0.32, y: 0.5}, {t: 20, x: 0.7, y: 0.3}],
};
let dir;

before(() => {
  dir = mkdtempSync(join(tmpdir(), 'pointer-wiring-'));
  copyFileSync(reference, join(dir, 'app.mp4'));
  writeFileSync(join(dir, 'app-pointer.json'), JSON.stringify(log));
});
after(() => rmSync(dir, {recursive: true, force: true}));

test('the pointer log sits beside its recording, in raw or reference alike', () => {
  assert.equal(pointerFileOf('video/raw/kinhin/app.mov'), 'video/raw/kinhin/app-pointer.json');
  assert.equal(pointerFileOf('adapters/kinhin/reference/app.mp4'), 'adapters/kinhin/reference/app-pointer.json');
});

test('a story is cut to its own time: readings before it go, the rest count from its start', () => {
  const cut = cutPointerLog(log, 4, 5);
  assert.deepEqual(cut.samples, [{t: 0, x: 0.3, y: 0.5}, {t: 5, x: 0.6, y: 0.6}]);
  assert.deepEqual(cut.clicks, [{t: 1, x: 0.3, y: 0.5}, {t: 1.5, x: 0.32, y: 0.5}]);
});

test('make-reference.sh calls the cut from the command line and writes the same log', () => {
  const input = join(dir, 'raw-pointer.json');
  const output = join(dir, 'reference-pointer.json');
  writeFileSync(input, JSON.stringify(log));
  execFileSync('node', [join(root, 'scripts/pointer-log.mjs'), input, output, '4', '5'], {cwd: root});
  assert.deepEqual(JSON.parse(readFileSync(output, 'utf8')), cutPointerLog(log, 4, 5));
});

test('the command line refuses a missing argument', () => {
  assert.throws(() => execFileSync('node', [join(root, 'scripts/pointer-log.mjs'), 'in.json'], {cwd: root, stdio: 'pipe'}));
});

test("autoZoom becomes camera keyframes from the clip's log", () => {
  const spec = autoZoomSpec({clip: 'app', autoZoom: true}, {file: join(dir, 'app.mp4'), length: 10, where: 'scene "x"'});
  assert.equal(spec.camera.length, 2);
  assert.equal(spec.camera[0].zoom, 1.6);
  assert.equal(spec.autoZoom, true);
});

test('props without autoZoom come back as they are', () => {
  const spec = {clip: 'app', camera: [{at: 1, zoom: 2}]};
  assert.equal(autoZoomSpec(spec, {file: join(dir, 'app.mp4'), length: 10}), spec);
});

test('autoZoom with no click in the scene leaves the camera where it is', () => {
  const spec = autoZoomSpec({clip: 'app', autoZoom: true}, {file: join(dir, 'app.mp4'), length: 2, where: 'scene "x"'});
  assert.equal(spec.camera, undefined);
});

test('autoZoom is refused with a camera, and with no log beside the recording', () => {
  assert.throws(
    () => autoZoomSpec({clip: 'app', autoZoom: true, camera: [{at: 1, zoom: 2}]}, {file: join(dir, 'app.mp4'), length: 10, where: 'scene "x"'}),
    /keep one/,
  );
  assert.throws(
    () => autoZoomSpec({clip: 'app', autoZoom: true}, {file: join(dir, 'missing.mp4'), length: 10, where: 'scene "x"'}),
    /record the clip with --pointer/,
  );
});

test('the zoom lands at the clicked time: frames match before it and differ while it is on', {skip: !has('ffmpeg') && 'needs ffmpeg'}, () => {
  const plainFile = join(dir, 'plain.mp4');
  const zoomedFile = join(dir, 'zoomed.mp4');
  const spec = autoZoomSpec({clip: 'app', autoZoom: true}, {file: join(dir, 'app.mp4'), length: 10, where: 'scene "x"'});
  applyCamera({clip: join(dir, 'app.mp4'), out: plainFile, props: {}, start: 0, speed: 1, length: 10});
  applyCamera({clip: join(dir, 'app.mp4'), out: zoomedFile, props: spec, start: 0, speed: 1, length: 10});
  const frame = (file, t) =>
    execFileSync('ffmpeg', ['-nostdin', '-loglevel', 'error', '-ss', String(t), '-i', file, '-frames:v', '1', '-vf', 'scale=160:-2', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], {maxBuffer: 1 << 24});
  assert.ok(frame(plainFile, 0.5).equals(frame(zoomedFile, 0.5)), 'before the first click the picture is the same');
  assert.ok(!frame(plainFile, 6).equals(frame(zoomedFile, 6)), 'at the click the camera has zoomed in');
});
