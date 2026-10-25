import assert from 'node:assert/strict';
import {test} from 'node:test';
import {autoCamera, sceneTime, wantsCamera} from '../../scripts/camera.mjs';
import {validateCamera} from '../../shared/resolve.mjs';

test('a constant pace turns clip seconds into scene seconds', () => {
  assert.equal(sceneTime(4, 2), 2);
  assert.equal(sceneTime(3), 3);
  assert.equal(sceneTime(3, '2'), 1.5);
});

test('a speed list is followed piece by piece', () => {
  const pace = [{until: 2, speed: 4}, {speed: 1}];
  assert.equal(sceneTime(2, pace, 0), 0.5); // the first two seconds play at 4x
  assert.equal(sceneTime(3, pace, 0), 1.5); // then one second at 1x
});

test('clicks that come close together zoom in on their centre, then back out', () => {
  const clicks = [
    {t: 2.0, x: 0.3, y: 0.4},
    {t: 2.5, x: 0.31, y: 0.42},
    {t: 10, x: 0.8, y: 0.2},
  ];
  const keys = autoCamera(clicks, {length: 20});
  assert.deepEqual(keys.map((k) => k.at), [1.4, 4, 9.4, 11.5]);
  assert.deepEqual(keys.map((k) => k.zoom), [1.6, 1, 1.6, 1]);
  assert.ok(Math.abs(keys[0].to[0] - 0.305) < 1e-9 && Math.abs(keys[0].to[1] - 0.41) < 1e-9);
  assert.deepEqual(keys[2].to, [0.8, 0.2]);
});

test('a zoom-out is skipped when the next burst starts before it would finish', () => {
  // The clicks are far apart, but the second burst starts 0.6 s before the first zoom-out would begin.
  const keys = autoCamera([{t: 2, x: 0.1, y: 0.1}, {t: 4, x: 0.9, y: 0.9}], {length: 20});
  assert.deepEqual(keys.map((k) => k.at), [1.4, 3.4, 5.5]);
  assert.deepEqual(keys.map((k) => k.zoom), [1.6, 1.6, 1]);
});

test('clicks before the story, or after the scene, are left out', () => {
  assert.deepEqual(autoCamera([{t: 1, x: 0.5, y: 0.5}], {cut: 2, length: 10}), []);
  assert.deepEqual(autoCamera([{t: 19.9, x: 0.5, y: 0.5}], {length: 19}), []);
});

test('the zoom is kept between 1 and 4, and the settings can be given', () => {
  const [zoomIn] = autoCamera([{t: 1, x: 0.5, y: 0.5}], {zoom: 9, lead: 0, length: 10});
  assert.equal(zoomIn.zoom, 4);
  const [tuned] = autoCamera([{t: 1, x: 0.5, y: 0.5}], {zoom: 2, lead: 0.25, length: 10});
  assert.equal(tuned.zoom, 2);
  assert.equal(tuned.at, 0.75);
});

test('the clicks of a speed-ramped clip land where the ramp puts them', () => {
  // Story starts at 0; the first 4 clip seconds play at 4x, so a click at clip second 4 is at scene second 1.
  const [zoomIn] = autoCamera([{t: 4, x: 0.5, y: 0.5}], {pace: [{until: 4, speed: 4}, {speed: 1}], ramp: 0, lead: 0, length: 10});
  assert.equal(zoomIn.at, 1);
});

test('autoZoom is camera work, so it asks for the pre-pass', () => {
  assert.equal(wantsCamera({autoZoom: true}), true);
});

test('autoZoom is checked with the camera props', () => {
  assert.deepEqual(validateCamera({autoZoom: true}, 'scene "a"'), []);
  assert.deepEqual(validateCamera({autoZoom: {zoom: 2, hold: 1}}, 'scene "a"'), []);
  assert.ok(validateCamera({autoZoom: 'yes'}, 'scene "a"').some((p) => p.includes('must be true, or')));
  assert.ok(validateCamera({autoZoom: true, camera: [{at: 1, zoom: 2}]}, 'scene "a"').some((p) => p.includes('keep one')));
  assert.ok(validateCamera({autoZoom: {zoom: 9}}, 'scene "a"').some((p) => p.includes('from 1 to 4')));
  assert.ok(validateCamera({autoZoom: {move: 0.5}}, 'scene "a"').some((p) => p.includes('autoZoom.move is not a setting')));
});
