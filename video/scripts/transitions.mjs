// How scenes hand over to each other in the cut (see TRANSITIONS in shared/resolve.mjs).
// The default, `fade`, dips every scene through the backdrop colour at both ends and the scene clips are simply joined.
// Any other transition is an ffmpeg `xfade` centred on the cut: the scene before runs half the transition past its end
// and the scene after starts half the transition early (both held on their first and last frame), so the cut, every
// scene's start on the clock and the voice stay exactly where timeline.json put them, and the picture is as long as before.
import {TRANSITIONS, TRANSITION_LENGTH} from '../shared/resolve.mjs';

/**
 * The cut between each scene and the next. `scenes` is [{length, transition?}] in order; `fallback` is the project's
 * `transition`. A scene's own `transition` is how it comes in. The length is capped at the shorter of the two scenes.
 */
export function planCuts(scenes, fallback = 'fade') {
  return scenes.slice(1).map((next, i) => {
    const name = next.transition ?? fallback ?? 'fade';
    if (!(name in TRANSITIONS)) throw new Error(`unknown transition "${name}" (${Object.keys(TRANSITIONS).join(', ')})`);
    return {name, xfade: TRANSITIONS[name].xfade, length: Math.min(TRANSITION_LENGTH, scenes[i].length, next.length)};
  });
}

/** For scene `i`: how much of its neighbours' transitions it carries as extra frames, and whether it fades through the backdrop at each end. */
export function partPlan(cuts, i) {
  const before = cuts[i - 1];
  const after = cuts[i];
  return {
    padStart: before?.xfade ? before.length / 2 : 0,
    padEnd: after?.xfade ? after.length / 2 : 0,
    fadeIn: !before?.xfade,
    fadeOut: !after?.xfade,
  };
}

/**
 * The filter graph that joins the scene clips (inputs 0..n-1, each already padded as partPlan says) into one picture, as
 * [graph, outputLabel]. Fade cuts are plain joins; the others cross over for the transition's length.
 */
export function joinGraph(scenes, cuts, fps) {
  const round = (x) => Math.round(x * 1000) / 1000;
  const steps = scenes.map((_, i) => `[${i}:v]setpts=PTS-STARTPTS,fps=${fps},format=yuv420p[p${i}]`);
  let label = 'p0';
  let end = scenes[0].length + partPlan(cuts, 0).padEnd; // where the picture built so far ends on the clock
  for (let i = 1; i < scenes.length; i++) {
    const cut = cuts[i - 1];
    const {padStart, padEnd} = partPlan(cuts, i);
    const next = `x${i}`;
    steps.push(
      cut.xfade
        ? `[${label}][p${i}]xfade=transition=${cut.xfade}:duration=${round(cut.length)}:offset=${round(end - cut.length)}[${next}]`
        : `[${label}][p${i}]concat=n=2:v=1:a=0,fps=${fps}[${next}]`,
    );
    end = (cut.xfade ? end - cut.length : end) + padStart + scenes[i].length + padEnd;
    label = next;
  }
  return [steps.join(';'), label];
}
