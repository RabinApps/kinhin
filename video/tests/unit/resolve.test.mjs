import assert from 'node:assert/strict';
import {test} from 'node:test';
import {FORMATS, SCENE_TYPES, deepMerge, fitScale, isNarrow, resolveFormat, resolveTheme, validateProject} from '../../shared/resolve.mjs';
import {readJson, root, themeNames} from '../helpers.mjs';
import {join} from 'node:path';

const themes = Object.fromEntries(themeNames().map((n) => [n, readJson(join(root, 'themes', `${n}.json`))]));

test('there are at least the five built-in themes', () => {
  for (const n of ['paper', 'clean', 'midnight', 'blueprint', 'chalk']) assert.ok(n in themes, n);
});

test('every theme defines every colour, the font, the backdrop, the device look and the captions', () => {
  const hex = /^#[0-9a-f]{6}$/i;
  for (const [name, t] of Object.entries(themes)) {
    assert.equal(t.name, name, `${name}: the name matches the file`);
    assert.ok(t.font.family && t.font.fallback, `${name}: font`);
    for (const k of ['ink', 'muted', 'paper', 'accent', 'card', 'track', 'line']) assert.match(t.colors[k], hex, `${name}: colors.${k}`);
    for (const k of ['from', 'to']) assert.match(t.background[k], hex, `${name}: background.${k}`);
    for (const k of ['lid', 'baseFrom', 'baseTo', 'thumb', 'windowBar', 'windowBody']) assert.match(t.device[k], hex, `${name}: device.${k}`);
    for (const k of ['from', 'to']) assert.match(t.device.wallpaper[k], hex, `${name}: device.wallpaper.${k}`);
    assert.ok(t.device.shadow > 0 && t.device.shadow < 1, `${name}: shadow`);
    assert.ok(['light', 'dark'].includes(t.device.terminal), `${name}: device.terminal`);
    assert.match(t.caption.text, hex);
    assert.match(t.caption.outline, hex);
    assert.ok(t.caption.size > 0);
  }
});

test('themes keep text readable: ink against the backdrop and the card', () => {
  const lum = (h) => {
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const contrast = (a, b) => (Math.max(lum(a), lum(b)) + 0.05) / (Math.min(lum(a), lum(b)) + 0.05);
  for (const [name, t] of Object.entries(themes)) {
    assert.ok(contrast(t.colors.ink, t.background.from) >= 7, `${name}: ink on the backdrop`);
    assert.ok(contrast(t.colors.ink, t.colors.card) >= 7, `${name}: ink on cards`);
    assert.ok(contrast(t.colors.muted, t.background.to) >= 3, `${name}: muted text on the backdrop`);
  }
});

test('resolveTheme merges overrides over the theme and builds a CSS font stack', () => {
  const t = resolveTheme(themes, 'paper', {colors: {accent: '#ff7a59'}, font: {family: 'Georgia'}});
  assert.equal(t.colors.accent, '#ff7a59');
  assert.equal(t.colors.ink, themes.paper.colors.ink, 'other colours are untouched');
  assert.match(t.font.css, /^Georgia, /);
  assert.match(resolveTheme(themes, 'blueprint').font.css, /^"DejaVu Sans Mono", |^DejaVu/);
});

test('resolveTheme names the available themes when one is unknown', () => {
  assert.throws(() => resolveTheme(themes, 'nope'), /unknown theme "nope".*paper/);
});

test('deepMerge replaces arrays and scalars and merges objects', () => {
  assert.deepEqual(deepMerge({a: {b: 1, c: 2}, l: [1, 2]}, {a: {b: 9}, l: [3]}), {a: {b: 9, c: 2}, l: [3]});
  assert.deepEqual(deepMerge({a: 1}, undefined), {a: 1});
});

test('formats: sizes, narrowness and fit', () => {
  assert.deepEqual([FORMATS['16:9'].width, FORMATS['16:9'].height], [1920, 1080]);
  assert.deepEqual([FORMATS['9:16'].width, FORMATS['9:16'].height], [1080, 1920]);
  assert.deepEqual([FORMATS['4:5'].width, FORMATS['4:5'].height], [1080, 1350]);
  assert.deepEqual([FORMATS['1:1'].width, FORMATS['1:1'].height], [1080, 1080]);
  assert.equal(isNarrow(resolveFormat('16:9')), false);
  for (const f of ['9:16', '4:5', '1:1']) assert.equal(isNarrow(resolveFormat(f)), true, f);
  assert.equal(fitScale(resolveFormat('16:9')), 1);
  assert.ok(Math.abs(fitScale(resolveFormat('9:16')) - 1080 / 1700) < 1e-9);
  assert.throws(() => resolveFormat('21:9'), /unknown format "21:9"/);
});

test('every scene type is canvas or clip with a positive-or-zero minimum length', () => {
  for (const [name, t] of Object.entries(SCENE_TYPES)) {
    assert.ok(['canvas', 'clip'].includes(t.kind), name);
    assert.ok(t.minLength >= 0, name);
  }
  for (const n of ['title', 'statement', 'queue', 'parallel', 'map', 'outro', 'stats', 'steps', 'code', 'compare', 'device', 'terminal']) assert.ok(n in SCENE_TYPES, n);
});

test('validateProject says what is wrong', () => {
  assert.match(validateProject({}).join(), /needs a "scenes" list/);
  const problems = validateProject({scenes: [{id: 'a', type: 'title', narration: 'x'}, {id: 'a', type: 'nope', narration: 'x'}, {type: 'title'}]});
  assert.match(problems.join('\n'), /the id is used twice/);
  assert.match(problems.join('\n'), /unknown type "nope"/);
  assert.match(problems.join('\n'), /has no "id"/);
  assert.match(problems.join('\n'), /neither "narration" nor "cues"/);
  assert.deepEqual(validateProject({scenes: [{id: 'a', type: 'title', narration: 'hi'}]}), []);
});

// ---- captions ---------------------------------------------------------------------------------------------------------
import {CAPTION_STYLES, assColor, resolveCaptions, validateCaptions} from '../../shared/resolve.mjs';

const theme = resolveTheme(themes, 'paper');
const caps = (over = {}) => resolveCaptions({theme, ...over});

test('captions default to burned in on the clip scenes, outlined, positioned automatically', () => {
  const c = caps();
  assert.deepEqual([c.burn, c.scenes, c.style, c.border, c.position, c.scale, c.bold, c.sidecar], [true, 'clips', 'outline', 'outline', 'auto', 1, false, true]);
  assert.equal(c.font, 'Inter');
  assert.equal(c.text, theme.caption.text);
});

test('every style preset resolves, and the five documented styles exist', () => {
  assert.deepEqual(Object.keys(CAPTION_STYLES).sort(), ['bold', 'box', 'minimal', 'outline', 'shadow']);
  for (const style of Object.keys(CAPTION_STYLES)) assert.equal(caps({project: {captions: {style}}}).style, style);
  assert.equal(caps({project: {captions: {style: 'box'}}}).border, 'box');
  assert.equal(caps({project: {captions: {style: 'minimal'}}}).border, 'none');
  assert.ok(caps({project: {captions: {style: 'bold'}}}).bold);
  assert.equal(caps({project: {captions: {style: 'bold'}}}).scale, 1.25);
  assert.equal(caps({project: {captions: {style: 'bold', size: 2}}}).scale, 2.5, 'size multiplies the preset');
});

test('precedence: theme, then adapter, then project, then the environment', () => {
  const adapter = {captions: {burn: false, style: 'box', position: 'top'}};
  assert.equal(caps({adapter}).burn, false, 'the adapter turns them off');
  assert.equal(caps({adapter}).style, 'box');
  assert.equal(caps({adapter, project: {captions: {burn: true}}}).burn, true, 'the project beats the adapter');
  assert.equal(caps({adapter, project: {captions: {burn: true}}}).position, 'top', 'what the project does not say comes from the adapter');
  assert.equal(caps({adapter, env: {VIDEO_CAPTIONS: 'on'}}).burn, true, 'the environment beats the adapter');
  assert.equal(caps({project: {captions: {burn: true}}, env: {VIDEO_CAPTIONS: 'off'}}).burn, false, 'and the project');
  assert.equal(caps({project: {captions: {style: 'box'}}, env: {VIDEO_CAPTION_STYLE: 'shadow'}}).style, 'shadow');
  assert.equal(caps({env: {NO_CAPTIONS: '1'}}).burn, false, 'the older switch still works');
});

test('VIDEO_CAPTIONS=all burns every scene; CAPTION_SCENES picks scenes', () => {
  assert.equal(caps({env: {VIDEO_CAPTIONS: 'all'}}).scenes, 'all');
  assert.deepEqual(caps({env: {CAPTION_SCENES: 'app,install'}}).scenes, ['app', 'install']);
  assert.deepEqual(caps({project: {captions: {scenes: ['intro']}}}).scenes, ['intro']);
});

test('colours and the font can be overridden; a dark theme with a box caption keeps its box', () => {
  const c = caps({project: {captions: {color: '#ffee00', outlineColor: '#112233', boxColor: '#ff000080', font: 'Georgia'}}});
  assert.deepEqual([c.text, c.outline, c.box, c.font], ['#ffee00', '#112233', '#ff000080', 'Georgia']);
  const boxed = {...theme, caption: {...theme.caption, box: true}};
  assert.equal(resolveCaptions({theme: boxed}).style, 'box', 'a theme that asks for a box gets the box style by default');
});

test('bad captions settings are reported in words', () => {
  const bad = {burn: 'yes', style: 'neon', position: 'left', scenes: 'some', size: 9, color: 'red', boxColor: '#12'};
  const text = validateCaptions(bad).join('\n');
  for (const piece of ['captions.burn must be', 'captions.style "neon" is not one of', 'captions.position "left"', 'captions.scenes must be', 'captions.size must be', 'captions.color must be a hex', 'captions.boxColor must be a hex']) assert.match(text, new RegExp(piece.replace(/[.()]/g, '\\$&')));
  assert.throws(() => caps({project: {captions: {style: 'neon'}}}), /captions.style "neon"/);
  assert.throws(() => caps({env: {VIDEO_CAPTIONS: 'maybe'}}), /VIDEO_CAPTIONS must be on, off or all/);
  assert.throws(() => caps({env: {VIDEO_CAPTION_STYLE: 'neon'}}), /unknown caption style "neon"/);
  assert.match(validateProject({scenes: [{id: 'a', type: 'title', narration: 'x'}], captions: {style: 'neon'}}).join(), /captions.style/);
  assert.deepEqual(validateCaptions(undefined), []);
});

test('assColor converts to libass order and inverts opacity', () => {
  assert.equal(assColor('#ffffff'), '&H00FFFFFF&');
  assert.equal(assColor('#102030'), '&H00302010&', 'blue, green, red');
  assert.equal(assColor('#000000b3'), '&H4C000000&', 'b3 = 70% opaque = 0x4C transparent');
  assert.equal(assColor('#ff000000'), '&HFF0000FF&', 'fully transparent red');
});
