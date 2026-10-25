// Speed ramps: a recording that plays fast through the waiting and slows down for the moment that matters.
//
//   speed: [{until: 20, speed: 8}, {until: 30, speed: 1}, {speed: 4}]     ramp: 0.4
//       the clip plays at 8x until second 20 of the recording (counted from where the story starts), at 1x until second 30, then
//       at 4x to the end. Where the speed changes it eases over `ramp` output seconds (default 0.4) instead of jumping.
//
// An ease is a handful of short pieces at speeds between the two, so everything here is trim + setpts + concat in ffmpeg:
// no frame blending, and nothing to render that a constant `speed` does not.
const STEPS = 6; // pieces in each ease
const RAMP = 0.4;

/**
 * Turns a `speed` list into the pieces of the recording to play: [{from, to, speed}] in source seconds from the story's start.
 * The last piece has `to: Infinity`: it plays to the end of the scene. An ease starts where the segment before it ends, so a
 * segment's `until` is where its speed starts to change.
 */
export function speedPieces(segments, ramp = RAMP) {
  const pieces = [];
  let at = 0; // where in the recording the next piece starts
  let before = null;
  for (const seg of segments) {
    const end = seg.until ?? Infinity;
    if (before !== null && ramp > 0 && before !== seg.speed) {
      for (let k = 0; k < STEPS; k++) {
        const speed = before * (seg.speed / before) ** ((k + 0.5) / STEPS);
        const to = at + speed * (ramp / STEPS);
        pieces.push({from: at, to, speed});
        at = to;
      }
    }
    if (end > at) {
      pieces.push({from: at, to: end, speed: seg.speed});
      at = end;
    }
    before = seg.speed;
  }
  return pieces;
}

/** How long the closed pieces play for, in output seconds (the last piece runs for as long as the scene does). */
export function outputLength(segments, ramp = RAMP) {
  return speedPieces(segments, ramp).reduce((sum, p) => (Number.isFinite(p.to) ? sum + (p.to - p.from) / p.speed : sum), 0);
}

/** How many seconds of the recording a scene of `length` seconds uses, from the story's start. */
export function sourceSeconds(segments, length, ramp = RAMP) {
  const pieces = speedPieces(segments, ramp);
  const last = pieces[pieces.length - 1];
  if (Number.isFinite(last.to)) return last.to;
  return last.from + Math.max(0, length - outputLength(segments, ramp)) * last.speed;
}

/**
 * The shortest a clip scene may be for its props: a speed list plays for at least as long as its closed pieces, so a short
 * narration never cuts a ramp off. A constant speed (or none) asks for nothing, as before.
 */
export function clipMinLength(props) {
  const own = Array.isArray(props?.speed) ? outputLength(props.speed, props.ramp) : 0;
  return Math.max(own + (props?.delay ?? 0), 0);
}

/** The ffmpeg filter text for the pieces: from input `in` (a label) to [out], each piece cut, retimed and joined. */
export function speedFilter(pieces, fps, input = '[0:v]', output = '[sp]') {
  const num = (x) => String(Math.round(x * 1000) / 1000);
  const labels = pieces.map((_, i) => `[p${i}]`);
  const split = pieces.length > 1 ? `${input}split=${pieces.length}${labels.join('')}` : `${input}null${labels[0]}`;
  const cuts = pieces.map((p, i) => `${labels[i]}trim=start=${num(p.from)}${Number.isFinite(p.to) ? `:end=${num(p.to)}` : ''},setpts=(PTS-STARTPTS)/${num(p.speed)},fps=${fps}[q${i}]`);
  const join = pieces.length > 1 ? `${pieces.map((_, i) => `[q${i}]`).join('')}concat=n=${pieces.length}:v=1:a=0${output}` : `[q0]null${output}`;
  return [split, ...cuts, join].join(';');
}
