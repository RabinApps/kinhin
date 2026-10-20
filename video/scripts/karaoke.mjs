// Word-by-word ("karaoke") captions: the caption style that lights each word up as it is spoken.
// Kokoro times a whole cue, not its words, so a cue's time is shared out over its words by their length (a pause after a
// comma or a full stop counts as a few letters), which tracks speech closely enough for a sentence-long cue.
// Used by scripts/assemble.mjs; the output is an ASS file for libass, which sweeps each word with a \kf tag.

/** Splits `total` centiseconds over `words` in proportion to their length. The shares add up to `total` exactly. */
export function wordCentiseconds(words, total) {
  const weight = (w) => Math.max(2, w.replace(/[^\p{L}\p{N}]/gu, '').length) + (/[.!?]$/.test(w) ? 3 : /[,;:]$/.test(w) ? 2 : 0);
  const weights = words.map(weight);
  const sum = weights.reduce((a, b) => a + b, 0);
  const shares = weights.map((w) => Math.floor((w / sum) * total));
  // The rounding left over goes to the words with the biggest fractions, so no word is short by a whole centisecond twice.
  const order = weights.map((w, i) => [(w / sum) * total - shares[i], i]).sort((a, b) => b[0] - a[0]);
  for (let left = total - shares.reduce((a, b) => a + b, 0), k = 0; left > 0; left--, k++) shares[order[k % order.length][1]]++;
  return shares;
}

/** The text of one cue as ASS: a \kf sweep per word, lines broken with \N where `lines` (already wrapped) breaks them. */
export function karaokeText(lines, seconds) {
  const words = lines.flat();
  const cs = wordCentiseconds(words, Math.max(words.length, Math.round(seconds * 100)));
  let i = 0;
  return lines
    .map((line) => line.map((word, n) => `{\\kf${cs[i++]}}${word}${n < line.length - 1 ? ' ' : ''}`).join(''))
    .join('\\N');
}

const clock = (x) => {
  const cs = Math.round(x * 100);
  const p = (n, w = 2) => String(n).padStart(w, '0');
  return `${Math.floor(cs / 360000)}:${p(Math.floor(cs / 6000) % 60)}:${p(Math.floor(cs / 100) % 60)}.${p(cs % 100)}`;
};
// A colour for a Style line: libass writes them &HAABBGGRR, without the closing & that `assColor` adds for force_style.
const styleColor = (c) => c.replace(/&$/, '');

/**
 * An ASS document for the cues of one caption group. `style` holds libass style fields by name (Fontname, Fontsize, Bold,
 * OutlineColour, BorderStyle, Outline, Shadow, BackColour, Alignment, MarginV: the same values assemble.mjs gives
 * force_style), `sung` is the colour of a word once spoken and `unsung` its colour before. `cues` are {start, end, lines}
 * with lines an array of word arrays. The script is 288 lines tall, the unit those values are measured in.
 */
export function assDocument({cues, style, sung, unsung, width, height}) {
  const s = {Bold: 0, Shadow: 0, Outline: 0, BorderStyle: 1, BackColour: '&H00000000&', ...style};
  const fields = [
    'Default', s.Fontname, s.Fontsize, styleColor(sung), styleColor(unsung), styleColor(s.OutlineColour), styleColor(s.BackColour),
    s.Bold, 0, 0, 0, 100, 100, 0, 0, s.BorderStyle, s.Outline, s.Shadow, s.Alignment, 0, 0, s.MarginV, 1,
  ];
  return [
    '[Script Info]', 'ScriptType: v4.00+', `PlayResX: ${Math.round((288 * width) / height)}`, 'PlayResY: 288', 'WrapStyle: 2', 'ScaledBorderAndShadow: yes', '',
    '[V4+ Styles]',
    'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
    `Style: ${fields.join(',')}`, '',
    '[Events]', 'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
    ...cues.map((c) => `Dialogue: 0,${clock(c.start)},${clock(c.end)},Default,,0,0,0,,${karaokeText(c.lines, c.end - c.start)}`),
    '',
  ].join('\n');
}
