import assert from 'node:assert/strict';
import {test} from 'node:test';
import {assDocument, escapeAss, karaokeText, wordCentiseconds} from '../../scripts/karaoke.mjs';

test('a cue is shared out over its words by length, and the shares add up exactly', () => {
  const words = ['Every', 'job', 'gets', 'a', 'fresh', 'VM,', 'deleted', 'when', 'it', 'is', 'done.'];
  for (const total of [11, 100, 399, 400, 1234]) {
    const cs = wordCentiseconds(words, total);
    assert.equal(cs.reduce((a, b) => a + b, 0), total, `shares for ${total}`);
    assert.ok(cs.every((n) => n >= 0));
  }
  const cs = wordCentiseconds(words, 400);
  assert.ok(cs[6] > cs[1], 'a long word ("deleted") gets longer than a short one ("job")');
  assert.ok(cs[10] > cs[7], 'the full stop after "done." adds a pause');
});

test('a word with no letters still gets a share, and a lone word gets the whole cue', () => {
  assert.deepEqual(wordCentiseconds(['—', 'ok'], 40).reduce((a, b) => a + b, 0), 40);
  assert.ok(wordCentiseconds(['—', 'ok'], 40)[0] > 0);
  assert.deepEqual(wordCentiseconds(['Hello'], 123), [123]);
});

test('karaokeText sweeps each word, keeps the spaces inside the sweeps and breaks lines with \\N', () => {
  const text = karaokeText([['Hello', 'there'], ['friend']], 1.5);
  assert.match(text, /^\{\\kf\d+\}Hello \{\\kf\d+\}there\\N\{\\kf\d+\}friend$/);
  const total = [...text.matchAll(/\\kf(\d+)/g)].reduce((a, m) => a + Number(m[1]), 0);
  assert.equal(total, 150, 'the sweeps fill the cue');
});

test('assDocument writes a 288-line script with the style, the sung and unsung colours and one line per cue', () => {
  const style = {Fontname: 'Inter', Fontsize: '23.00', Bold: '-1', OutlineColour: '&H00000000&', BorderStyle: '1', Outline: '1.60', Shadow: '0', Alignment: '2', MarginV: '24.0'};
  const doc = assDocument({cues: [{start: 0.5, end: 4.5, lines: [['Hi', 'you']]}, {start: 3725.25, end: 3726, lines: [['Later']]}], style, sung: '&H00FFFFFF&', unsung: '&H8CFFFFFF&', width: 1080, height: 1920});
  assert.match(doc, /PlayResX: 162\nPlayResY: 288/, '1080x1920 at 288 lines tall');
  assert.match(doc, /WrapStyle: 2/, 'libass must not re-wrap what was wrapped already');
  assert.match(doc, /Style: Default,Inter,23.00,&H00FFFFFF,&H8CFFFFFF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,1.60,0,2,0,0,24.0,1/);
  assert.match(doc, /Dialogue: 0,0:00:00.50,0:00:04.50,Default,,0,0,0,,\{\\kf\d+\}Hi /);
  assert.match(doc, /Dialogue: 0,1:02:05.25,1:02:06.00,/, 'the clock runs past an hour');
});

test('braces and backslashes in the words cannot open an override block or run a command', () => {
  assert.equal(escapeAss('plain'), 'plain');
  assert.equal(escapeAss('{braces}'), '\\{braces\\}', 'libass prints an escaped brace');
  assert.equal(escapeAss('a\\Nb'), 'a\uFF3CNb', 'a backslash is not left to start \\N or \\h');
  const text = karaokeText([['In', '{x}', 'it']], 1);
  assert.match(text, /\{\\kf\d+\}\\\{x\\\} /);
});
