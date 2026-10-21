import assert from 'node:assert/strict';
import {test} from 'node:test';
import {FORMATS, SCENE_TYPES, deepMerge, fitScale, isNarrow, buildThemes, resolveFormat, resolveMusic, resolveTheme, validateMusic, validateProject, validateTheme, TRANSITIONS, validateCamera, validateClipSpec, validateSpeed, validateTransition, selectScenes, CAPTION_GROUPS} from '../../shared/resolve.mjs';
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

test('validateProject limits the characters on each slide', () => {
  const long = 'x'.repeat(91);
  const over = (scene) => validateProject({scenes: [{id: 'a', narration: 'hi', ...scene}]}).join('\n');
  assert.match(over({type: 'outro', props: {line: long}}), /"line" is 91 characters, the limit is 90/);
  assert.match(over({type: 'steps', props: {steps: ['ok', long]}}), /"steps" is 91 characters, the limit is 60/);
  assert.match(over({type: 'outro', props: {facts: Array(10).fill('abcdefghij')}}), /"facts" is 127 characters, the limit is 100/);
  assert.deepEqual(over({type: 'outro', props: {line: 'x'.repeat(90)}}), '');
  assert.match(over({type: 'compare', props: {left: {title: 'Before', items: ['ok', long]}, right: {title: 'After', items: []}}}), /"left.items" is 91 characters, the limit is 60/);
  assert.match(over({type: 'compare', props: {left: {title: 'x'.repeat(41), items: []}, right: {title: 'After', items: []}}}), /"left.title" is 41 characters, the limit is 40/);
  assert.deepEqual(over({type: 'compare', props: {left: {title: 'Before', items: ['x'.repeat(60)]}, right: {title: 'After', items: ['ok']}}}), '');
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

test('every style preset resolves, and the six documented styles exist', () => {
  assert.deepEqual(Object.keys(CAPTION_STYLES).sort(), ['bold', 'box', 'karaoke', 'minimal', 'outline', 'shadow']);
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
  for (const piece of ['captions.burn must be', 'captions.style "neon" is not one of', 'captions.position "left"', 'captions.scenes must be', 'captions.size must be', 'captions.color must be a hex', 'captions.boxColor must be a hex']) assert.ok(text.includes(piece), `expected "${piece}" in the message`);
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

test('the karaoke style is bold and outlined, lights words in the caption colour unless told otherwise', () => {
  const k = caps({project: {captions: {style: 'karaoke'}}});
  assert.equal(k.karaoke, true);
  assert.equal(k.border, 'outline');
  assert.ok(k.bold);
  assert.equal(k.highlight, theme.caption.text, 'the spoken words keep the caption colour; the unspoken ones are dimmed from it');
  assert.equal(caps({project: {captions: {style: 'karaoke', highlightColor: '#ffd166'}}}).highlight, '#ffd166');
  assert.equal(caps({project: {captions: {style: 'karaoke', color: '#eeeeee'}}}).highlight, '#eeeeee');
  assert.equal(caps({}).karaoke, false, 'no other style is word by word');
  assert.match(validateCaptions({highlightColor: 'gold'}).join(), /captions.highlightColor must be a hex/);
});

// ---- transitions and camera --------------------------------------------------------------------------------------------

test('transitions are named, default to the fade, and are checked on the project and on each scene', () => {
  assert.equal(TRANSITIONS.fade.xfade, null, 'the fade is the current behaviour, not an xfade');
  for (const [name, t] of Object.entries(TRANSITIONS)) assert.ok(name === 'fade' || t.xfade, `${name} names an ffmpeg xfade`);
  assert.deepEqual(validateTransition(undefined, 's'), []);
  assert.deepEqual(validateTransition('push', 's'), []);
  assert.match(validateTransition('spin', 'scene 2').join(), /scene 2: transition "spin" is not one of fade, dissolve, push/);
  const scenes = [{id: 'a', type: 'title', narration: 'x'}, {id: 'b', type: 'title', narration: 'x', transition: 'push'}];
  assert.deepEqual(validateProject({transition: 'wipe', scenes}), []);
  assert.match(validateProject({transition: 'spin', scenes}).join(), /the project: transition "spin"/);
  assert.match(validateProject({scenes: [{...scenes[0], transition: 'spin'}]}).join(), /scene 1 \("a"\): transition "spin"/);
});

test('camera, focus and cursor are checked on clip scenes and refused on drawn ones', () => {
  const good = {camera: [{at: 1, zoom: 2, to: [0.5, 0.5], move: 1}, {at: 4, zoom: 1}], focus: {from: 1, to: 3, box: [0.1, 0.1, 0.5, 0.5], dim: 0.5}, cursor: [{at: 1, to: [0.2, 0.2]}, {at: 2, to: [0.3, 0.3], click: true}]};
  assert.deepEqual(validateCamera(good, 's'), []);
  assert.deepEqual(validateCamera({}, 's'), [], 'all three are optional');
  const text = (props) => validateCamera(props, 's').join('\n');
  assert.match(text({camera: []}), /"camera" must be a list/);
  assert.match(text({camera: [{at: 2}, {at: 1}]}), /camera\[1\].at must be later than the one before it/);
  assert.match(text({camera: [{at: 1, zoom: 9}]}), /zoom must be a number from 1 to 4/);
  assert.match(text({camera: [{at: 1, to: [2, 0]}]}), /camera\[0\].to must be \[x, y\]/);
  assert.match(text({camera: [{at: 1, move: 0}]}), /move must be seconds above 0/);
  assert.match(text({focus: {from: 3, to: 2, box: [0, 0, 1, 1]}}), /needs "from" and "to"/);
  assert.match(text({focus: [{from: 1, to: 2, box: [0.5, 0.5, 0.4, 0.9]}]}), /focus\[0\].box must be \[x0, y0, x1, y1\]/);
  assert.match(text({focus: {from: 1, to: 2, box: [0, 0, 1, 1], dim: 1}}), /dim must be/);
  assert.match(text({cursor: [{at: 1}]}), /cursor\[0\].to must be \[x, y\]/);
  assert.match(text({cursor: [{at: 1, to: [0, 0], click: 'yes'}]}), /click must be true or false/);
  const device = {id: 'a', type: 'device', narration: 'x', props: {clip: 'app', camera: [{at: 1, zoom: 9}]}};
  assert.match(validateProject({scenes: [device]}).join(), /scene 1 \("a"\): camera\[0\].zoom/);
  assert.match(validateProject({scenes: [{id: 'a', type: 'title', narration: 'x', props: {title: 'T', camera: [{at: 1}]}}]}).join(), /work on device, terminal and split scenes only/);
});

test('a camera position may be the name of a target', () => {
  assert.deepEqual(validateCamera({camera: [{at: 1, target: 'fleet'}, {at: 3, to: 'list', zoom: 2}], focus: {from: 1, to: 2, box: 'fleet'}, cursor: [{at: 1, to: 'list'}]}, 's'), []);
  assert.match(validateCamera({camera: [{at: 1, target: 'a', to: [0.5, 0.5]}]}, 's').join(), /has both "target" and "to"/);
  assert.match(validateCamera({camera: [{at: 1, target: 3}]}, 's').join(), /camera\[0\].target must be the name of a target/);
  assert.match(validateCamera({cursor: [{at: 1, to: 3}]}, 's').join(), /cursor\[0\].to must be \[x, y\].*or the name of a target/);
});

test('an empty or bare entry in a camera, focus, cursor or speed list is a problem, not a crash', () => {
  const text = (props) => validateClipSpec(props, 's').join('\n');
  for (const entry of [null, 2, 'x', [1]]) {
    assert.match(text({camera: [entry]}), /camera\[0\] must be a keyframe/, String(entry));
    assert.match(text({focus: [entry]}), /focus\[0\] must be \{ from, to, box \}/, String(entry));
    assert.match(text({cursor: [entry]}), /cursor\[0\] must be a point/, String(entry));
    assert.match(text({speed: [entry, {speed: 1}]}), /speed\[0\] must be a segment/, String(entry));
  }
  assert.match(text({focus: null}), /focus must be/, 'a bare `focus:` in the file');
  assert.match(text({camera: [{at: 1, zoom: 2}, null, {at: 5}]}), /camera\[1\] must be a keyframe/, 'the rest of the list is still checked');
  assert.doesNotMatch(text({camera: [null]}), /at must be seconds/, 'one problem per entry');
});

test('speed is a number or a list of segments, each with `until` but the last', () => {
  const text = (props) => validateSpeed(props, 's').join('\n');
  assert.deepEqual(validateSpeed({speed: 2}, 's'), []);
  assert.deepEqual(validateSpeed({}, 's'), []);
  assert.deepEqual(validateSpeed({speed: 60}, 's'), [], 'a constant speed is any positive number, as it always was (a time-lapse may be 60x)');
  assert.deepEqual(validateSpeed({speed: 0.05}, 's'), []);
  assert.deepEqual(validateSpeed({speed: [{until: 20, speed: 8}, {until: 30, speed: 1}, {speed: 4}], ramp: 0.5}, 's'), []);
  for (const bad of [0, -2, '2', NaN, Infinity, null]) assert.match(text({speed: bad}), /speed must be a positive number, or a list/, String(bad));
  assert.match(text({speed: [{until: 5, speed: 99}, {speed: 1}]}), /speed\[0\].speed must be a number from 0.1 to 30/, 'the limits are for the speeds of a list');
  assert.match(text({speed: []}), /must not be an empty list/);
  assert.match(text({speed: [{speed: 2}, {speed: 1}]}), /speed\[0\].until must be source seconds/);
  assert.match(text({speed: [{until: 5, speed: 2}, {until: 4, speed: 1}, {speed: 1}]}), /speed\[1\].until must be source seconds, later than/);
  assert.match(text({speed: [{until: 5, speed: 2}, {until: 9, speed: 1}]}), /the last speed segment has no "until"/);
  assert.match(text({speed: [{until: 5, speed: 0}, {speed: 1}]}), /speed\[0\].speed must be a number/);
  assert.match(text({speed: [{until: 5, speed: 2}, {speed: 1}], ramp: 3}), /ramp must be seconds from 0 to 2/);
  assert.match(text({speed: 2, ramp: 0.5}), /ramp only applies when speed is a list/);
});

test('a split scene needs two clips; delay and ratio are checked, and delay is for panels only', () => {
  const split = (props) => validateProject({scenes: [{id: 's', type: 'split', narration: 'x', props}]}).join('\n');
  assert.equal(split({left: {clip: 'a'}, right: {clip: 'b', delay: 1.5, speed: [{until: 3, speed: 2}, {speed: 1}], camera: [{at: 1, target: 'x'}]}, ratio: 0.4}), '');
  assert.match(split({left: {clip: 'a'}}), /a split scene needs "right"/);
  assert.match(split({}), /needs "left".*needs "right"/s);
  assert.match(split({left: {clip: 'a'}, right: {clip: 'b'}, ratio: 0.9}), /ratio must be a number from 0.3 to 0.7/);
  assert.match(split({left: {clip: 'a'}, right: {clip: 'b', delay: 99}}), /scene 1 \("s"\): right: delay must be seconds from 0 to 30/);
  assert.match(split({left: {clip: 'a', camera: [{at: 1, zoom: 9}]}, right: {clip: 'b'}}), /left: camera\[0\].zoom/);
  assert.match(validateClipSpec({clip: 'a', delay: 2}, 'scene 2').join(), /"delay" works on the panels of a split scene only/);
  assert.deepEqual(validateClipSpec({clip: 'a', delay: 2}, 'p', {panel: true}), []);
  assert.ok('split' in SCENE_TYPES && SCENE_TYPES.split.kind === 'clip');
  assert.match(validateProject({scenes: [{id: 'a', type: 'title', narration: 'x', props: {title: 'T', ramp: 1}}]}).join(), /work on device, terminal and split scenes only/);
});

test('selectScenes picks scenes by id, in the video\'s own order, and says which ids it has', () => {
  const scenes = [{id: 'intro'}, {id: 'app'}, {id: 'outro'}];
  assert.equal(selectScenes(scenes, undefined), scenes);
  assert.equal(selectScenes(scenes, ''), scenes, 'no ids is every scene');
  assert.deepEqual(selectScenes(scenes, 'outro,app').map((s) => s.id), ['app', 'outro'], 'the video\'s order, not the order asked for');
  assert.deepEqual(selectScenes(scenes, ' app , ').map((s) => s.id), ['app'], 'spaces and empty entries are ignored');
  assert.deepEqual(selectScenes(scenes, ['intro']).map((s) => s.id), ['intro'], 'a list works too');
  assert.throws(() => selectScenes(scenes, 'app,nope,zip'), /no scene "nope", "zip" in this video \(its scenes: intro, app, outro\)/);
});

test('every scene type has its captions burned somewhere: each is in exactly one caption group', () => {
  for (const type of Object.keys(SCENE_TYPES)) assert.equal(CAPTION_GROUPS.filter((g) => g.includes(type)).length, 1, `${type} is in one group`);
  const drawn = CAPTION_GROUPS[2];
  for (const type of ['title', 'statement', 'queue', 'parallel', 'map', 'outro', 'stats', 'steps', 'code', 'compare']) assert.ok(drawn.includes(type), `${type} is a drawn scene`);
  assert.deepEqual(CAPTION_GROUPS.slice(0, 2), [['device'], ['terminal', 'split']]);
});

// ---- music ------------------------------------------------------------------------------------------------------------

const mus = (a) => resolveMusic({project: {}, adapter: {}, env: {}, ...a});
const SHA = 'a'.repeat(64);

test('no track selected means no music, and the defaults are a ducked bed at 0.35', () => {
  assert.equal(mus({}).enabled, false);
  const m = mus({project: {music: 'first-light-particles'}});
  assert.deepEqual([m.enabled, m.track, m.volume, m.duck, m.loop], [true, 'first-light-particles', 0.35, true, true]);
});

test('music: the adapter selects, the project overrides or turns it off, the environment wins', () => {
  const adapter = {music: {track: 'first-light-particles', volume: 0.2}};
  assert.equal(mus({adapter}).track, 'first-light-particles');
  assert.equal(mus({adapter}).volume, 0.2);
  assert.equal(mus({adapter, project: {music: {track: 'music/mine.mp3'}}}).track, 'music/mine.mp3');
  assert.equal(mus({adapter, project: {music: {track: 'music/mine.mp3'}}}).volume, 0.2);
  assert.equal(mus({adapter, project: {music: false}}).enabled, false);
  assert.equal(mus({adapter, env: {VIDEO_MUSIC: 'off'}}).enabled, false);
  assert.equal(mus({adapter, env: {NO_MUSIC: '1'}}).enabled, false);
  assert.equal(mus({adapter, env: {VIDEO_MUSIC: 'music/x.wav', VIDEO_MUSIC_VOLUME: '0.5'}}).track, 'music/x.wav');
  assert.equal(mus({adapter, env: {VIDEO_MUSIC_VOLUME: '0.5'}}).volume, 0.5);
});

test('a music URL needs its sha256, and bad values are named', () => {
  assert.throws(() => mus({project: {music: {track: 'https://example.com/a.mp3'}}}), /sha256/);
  assert.equal(mus({project: {music: {track: 'https://example.com/a.mp3', sha256: SHA}}}).enabled, true);
  assert.equal(mus({env: {VIDEO_MUSIC: 'https://example.com/a.mp3', VIDEO_MUSIC_SHA256: SHA}}).sha256, SHA);
  assert.throws(() => mus({env: {VIDEO_MUSIC: 'https://example.com/a.mp3'}}), /sha256/);
  assert.throws(() => mus({env: {VIDEO_MUSIC_VOLUME: '9'}}), /VIDEO_MUSIC_VOLUME/);
  assert.match(validateMusic({track: 'http://x/a.mp3', sha256: SHA}).join(), /https/);
  assert.match(validateMusic({volume: 3}).join(), /volume/);
  assert.match(validateMusic({fadeIn: -1, duck: 'yes'}).join(), /fadeIn/);
  assert.deepEqual(validateMusic(false), []);
  assert.match(validateProject({name: 'x', scenes: [], music: 7}).join(), /music/);
});

// ---- your own themes ----------------------------------------------------------------------------------------------------

test('every built-in theme is complete', () => {
  for (const [name, t] of Object.entries(themes)) assert.deepEqual(validateTheme(t), [], name);
});

test('validateTheme names what is missing or wrong', () => {
  assert.match(validateTheme({}).join(), /font\.family[\s\S]*colors/);
  const bad = structuredClone(themes.paper);
  bad.colors.ink = 'red';
  bad.device.terminal = 'purple';
  bad.device.shadow = 3;
  bad.caption.size = 0;
  const text = validateTheme(bad).join('; ');
  for (const part of ['colors.ink', 'device.terminal', 'device.shadow', 'caption.size']) assert.match(text, new RegExp(part.replace('.', '\\.')));
  assert.deepEqual(validateTheme(5), ['a theme must be an object']);
});

test('your own theme may extend another and change only what it wants', () => {
  const all = buildThemes(themes, {
    brand: {extends: 'midnight', colors: {accent: '#ff7a59'}},
    brandserif: {extends: 'brand', font: {family: 'Georgia'}},
  });
  assert.equal(all.brand.colors.accent, '#ff7a59');
  assert.equal(all.brand.colors.ink, themes.midnight.colors.ink, 'the rest comes from the theme it extends');
  assert.equal(all.brand.name, 'brand', 'named by its file');
  assert.equal(all.brandserif.colors.accent, '#ff7a59', 'an extension of an extension');
  assert.equal(all.brandserif.font.family, 'Georgia');
  assert.equal(all.brandserif.font.fallback, themes.midnight.font.fallback);
  assert.equal(Object.keys(all).length, Object.keys(themes).length + 2);
  assert.equal(themes.midnight.colors.accent, '#7aa2ff', 'the built-in theme is not changed');
  assert.match(resolveTheme(all, 'brandserif').font.css, /^Georgia, /);
});

test('a theme with a built-in name replaces it, and extends itself means the built-in', () => {
  const all = buildThemes(themes, {paper: {extends: 'paper', colors: {accent: '#123456'}}});
  assert.equal(all.paper.colors.accent, '#123456');
  assert.equal(all.paper.colors.ink, themes.paper.colors.ink);
  assert.equal(themes.paper.colors.accent, '#000000');
});

test('a theme with no extends must be complete, and every problem is reported together', () => {
  assert.throws(() => buildThemes(themes, {half: {colors: {ink: '#ffffff'}}}), /theme "half".*font\.family is missing.*extends/s);
  const complete = structuredClone(themes.chalk);
  assert.equal(buildThemes(themes, {mine: complete}).mine.name, 'mine');
  assert.throws(
    () => buildThemes(themes, {a: {extends: 'nope'}, b: {extends: 'c'}, c: {extends: 'b'}, 'bad name': {extends: 'paper'}}),
    (e) => /a.*nope.*does not exist/s.test(e.message) && /circle/.test(e.message) && /bad name.*letters, digits/.test(e.message),
  );
  assert.throws(() => buildThemes(themes, {x: {extends: 'x'}}), /names itself/);
  assert.throws(() => buildThemes(themes, {x: 'text'}), /must be an object/);
  assert.throws(() => buildThemes(themes, {x: {extends: 5}}), /must name a theme/);
});

test('a theme file cannot change what every object inherits', () => {
  const evil = JSON.parse('{"extends": "paper", "__proto__": {"polluted": true}, "colors": {"__proto__": {"polluted": true}}}');
  buildThemes(themes, {evil});
  assert.equal({}.polluted, undefined);
});

test('an unknown theme is reported with the themes that exist and where to add your own', () => {
  assert.throws(() => resolveTheme(themes, 'neon'), /unknown theme "neon".*paper.*\.kinhin\/videos\/themes\/neon\.json/s);
});
