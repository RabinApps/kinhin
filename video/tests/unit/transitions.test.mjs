import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {after, before, test} from 'node:test';
import {joinGraph, partPlan, planCuts} from '../../scripts/transitions.mjs';
import {has} from '../helpers.mjs';

const scenes = [{length: 3}, {length: 4, transition: 'push'}, {length: 3, transition: 'fade'}, {length: 0.4, transition: 'circle'}];

test('a project with no transitions plans fades only, and a scene sets how it comes in', () => {
  assert.deepEqual(planCuts(scenes.map((s) => ({length: s.length}))).map((c) => c.name), ['fade', 'fade', 'fade']);
  assert.deepEqual(planCuts(scenes).map((c) => c.name), ['push', 'fade', 'circle']);
  assert.deepEqual(planCuts(scenes.map((s) => ({length: s.length})), 'wipe').map((c) => c.name), ['wipe', 'wipe', 'wipe']);
  assert.deepEqual(planCuts([{length: 5}]), [], 'one scene has no cuts');
  assert.throws(() => planCuts([{length: 1}, {length: 1, transition: 'spin'}]), /unknown transition "spin"/);
});

test('a cut is never longer than the shorter scene beside it', () => {
  assert.deepEqual(planCuts(scenes).map((c) => c.length), [0.5, 0.5, 0.4]);
});

test('only crossing cuts add frames: half the transition to each side of the cut', () => {
  const cuts = planCuts(scenes);
  assert.deepEqual(partPlan(cuts, 0), {padStart: 0, padEnd: 0.25, fadeIn: true, fadeOut: false});
  assert.deepEqual(partPlan(cuts, 1), {padStart: 0.25, padEnd: 0, fadeIn: false, fadeOut: true}, 'the cut after it is a fade');
  assert.deepEqual(partPlan(cuts, 2), {padStart: 0, padEnd: 0.2, fadeIn: true, fadeOut: false});
  assert.deepEqual(partPlan(cuts, 3), {padStart: 0.2, padEnd: 0, fadeIn: false, fadeOut: true});
});

test('the graph joins fades and crosses over the others, each crossing starting half a transition before its cut', () => {
  const cuts = planCuts(scenes);
  const [graph, label] = joinGraph(scenes, cuts, 30);
  assert.equal(label, 'x3');
  assert.match(graph, /\[p0\]\[p1\]xfade=transition=slideleft:duration=0.5:offset=2.75\[x1\]/, 'the cut is at 3 s, so 2.75');
  assert.match(graph, /\[x1\]\[p2\]concat=n=2:v=1:a=0,fps=30\[x2\]/);
  assert.match(graph, /\[x2\]\[p3\]xfade=transition=circleopen:duration=0.4:offset=9.8\[x3\]/, 'the cut is at 10 s, so 9.8');
});

const ffmpeg = has('ffmpeg') && has('ffprobe');
let dir;
before(() => { dir = mkdtempSync(join(tmpdir(), 'transitions-')); });
after(() => rmSync(dir, {recursive: true, force: true}));

test('crossing and fading cuts together keep the picture exactly as long as the scenes', {skip: !ffmpeg && 'needs ffmpeg'}, () => {
  const cuts = planCuts(scenes.map((s, i) => (i === 3 ? {...s, length: 3} : s)));
  const lengths = [3, 4, 3, 3];
  const ff = (args) => execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', ...args]);
  lengths.forEach((length, i) => {
    const {padStart, padEnd} = partPlan(cuts, i);
    ff(['-f', 'lavfi', '-i', `testsrc2=s=160x90:r=30:d=${padStart + length + padEnd}`, '-pix_fmt', 'yuv420p', join(dir, `p${i}.mp4`)]);
  });
  const [graph, label] = joinGraph(lengths.map((length) => ({length})), cuts, 30);
  ff([...lengths.flatMap((_, i) => ['-i', join(dir, `p${i}.mp4`)]), '-filter_complex', graph, '-map', `[${label}]`, '-pix_fmt', 'yuv420p', join(dir, 'joined.mp4')]);
  const seconds = Number(execFileSync('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=duration', '-of', 'csv=p=0', join(dir, 'joined.mp4')]).toString());
  assert.ok(Math.abs(seconds - 13) < 0.1, `13 s of scenes, ${seconds} s of picture`);
});
