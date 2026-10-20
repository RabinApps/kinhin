import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {after, before, test} from 'node:test';
import {has, root} from '../helpers.mjs';

const ffmpeg = has('ffmpeg') && has('ffprobe') && has('python3');
let dir;
before(() => { dir = mkdtempSync(join(tmpdir(), 'split-')); });
after(() => rmSync(dir, {recursive: true, force: true}));

const look = (width, height, narrow) => ({
  VIDEO_W: String(width), VIDEO_H: String(height), VIDEO_FIT: narrow ? '0.3175' : '0.5', VIDEO_NARROW: narrow ? '1' : '0',
  BG_FROM: '0xf5f5f7', BG_TO: '0xe8e8ee', BAR_COLOR: '0xe6e6e6', BODY_COLOR: '0xfafafa', SHADOW_ALPHA: '0.3',
});

// The mean colour of a region of one frame, as {r, g, b}.
const mean = (file, at, crop) => {
  const out = execFileSync('ffmpeg', ['-nostdin', '-loglevel', 'error', '-ss', String(at), '-i', file, '-frames:v', '1', '-vf', `crop=${crop},scale=1:1:flags=area,format=rgb24`, '-f', 'rawvideo', '-']);
  return {r: out[0], g: out[1], b: out[2]};
};
// A colour name for a mean colour; the pale backdrop and the window bodies are all 'grey' (no channel stands 60 above the others).
const dominant = ({r, g, b}) => {
  const [top, ...rest] = [[r, 'red'], [g, 'green'], [b, 'blue']].sort((x, y) => y[0] - x[0]);
  return top[0] - rest[0][0] > 60 ? top[1] : 'grey';
};

function clips() {
  const left = join(dir, 'left.mp4');
  const right = join(dir, 'right.mp4');
  // Left: red. Right: green for a second, then blue.
  execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=red:s=320x200:r=30:d=6', '-pix_fmt', 'yuv420p', left]);
  execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=green:s=320x200:r=30:d=1', '-f', 'lavfi', '-i', 'color=c=blue:s=320x200:r=30:d=5', '-filter_complex', '[0][1]concat=n=2:v=1:a=0,format=yuv420p', right]);
  return {left, right};
}

function split(args, env) {
  const r = spawnSync('bash', ['scripts/frame-split.sh', ...args], {cwd: root, env: {...process.env, ...env}, encoding: 'utf8'});
  assert.equal(r.status, 0, r.stderr);
}

test('side by side: the left clip is on the left, the right on the right, the right one starts after its delay', {skip: !ffmpeg && 'needs ffmpeg'}, () => {
  const {left, right} = clips();
  const out = join(dir, 'wide.mp4');
  split([left, right, out, '5', '0', '1.5', '1', '0', '0.5'], look(960, 540, false));
  assert.equal(execFileSync('ffprobe', ['-v', 'error', '-select_streams', 'v', '-show_entries', 'stream=width,height', '-of', 'csv=p=0:s=x', out]).toString().trim(), '960x540');
  const length = Number(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', out]).toString());
  assert.ok(Math.abs(length - 5) < 0.1, `5 s, got ${length}`);
  // The windows' middles: the left column is x 30-470, the right x 490-930, both centred on y 270.
  const leftMid = '100:50:190:245';
  const rightMid = '100:50:660:245';
  assert.equal(dominant(mean(out, 0.5, leftMid)), 'red');
  assert.equal(dominant(mean(out, 0.5, rightMid)), 'green', 'the delayed clip waits on its first frame');
  assert.equal(dominant(mean(out, 2.0, rightMid)), 'green', 'still on green: it has played 0.5 s of its 1 s of green');
  assert.equal(dominant(mean(out, 4.0, rightMid)), 'blue', 'and plays on after the delay');
  assert.equal(dominant(mean(out, 4.0, leftMid)), 'red');
});

test('in a portrait frame the clips are stacked, the left one on top', {skip: !ffmpeg && 'needs ffmpeg'}, () => {
  const {left, right} = clips();
  const out = join(dir, 'tall.mp4');
  split([left, right, out, '3', '0', '0', '0', '0', '0.5'], look(540, 960, true));
  assert.equal(execFileSync('ffprobe', ['-v', 'error', '-select_streams', 'v', '-show_entries', 'stream=width,height', '-of', 'csv=p=0:s=x', out]).toString().trim(), '540x960');
  const top = '100:50:220:190';
  const bottom = '100:50:220:515';
  assert.equal(dominant(mean(out, 0.5, top)), 'red');
  assert.equal(dominant(mean(out, 0.5, bottom)), 'green');
  assert.equal(dominant(mean(out, 2.0, bottom)), 'blue');
  assert.equal(dominant(mean(out, 0.5, '540:75:0:880')), 'grey', 'the bottom of the frame is left for the captions');
});

test('a usage mistake is reported, not a broken video', {skip: !ffmpeg && 'needs ffmpeg'}, () => {
  const r = spawnSync('bash', ['scripts/frame-split.sh', 'only-one.mp4'], {cwd: root, env: {...process.env, ...look(960, 540, false)}, encoding: 'utf8'});
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /usage: frame-split.sh/);
});
