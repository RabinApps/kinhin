import {Rect, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, createRefArray, waitFor} from '@motion-canvas/core';
import {fit, format, narrow, props} from '../config';
import {C, FONT, holdFor, stage} from '../stage';

// One runner, one job at a time, a queue that only grows. Wide frames: a row of jobs beside the runner.
// Portrait and square frames: a column of jobs stacking up above the runner.
export default makeScene2D(function* (view) {
  const root = stage(view);
  const jobs = createRefArray<Rect>();
  const caption = createRef<Txt>();
  const count: number = props.count ?? 7;
  // Narrow frames: stack the jobs as tall as the frame allows, with the runner under them.
  const halfHeight = format.height / fit / 2;
  const space = narrow ? Math.min(190, (110 + halfHeight - 175) / Math.max(1, count - 1)) : 150;
  const box = narrow ? Math.min(170, space * 0.88) : 120;
  const runnerSize = narrow ? 320 : 260;
  const runnerY = narrow ? 110 + box / 2 + 30 + runnerSize / 2 : 0;
  const jobPos = (i: number): [number, number] => (narrow ? [0, 110 - i * space] : [300 - i * space, 0]);

  root.add(
    <>
      <Rect width={runnerSize} height={runnerSize} radius={32} lineWidth={8} stroke={C.ink} fill={C.card} x={narrow ? 0 : 520} y={runnerY}>
        <Txt text={props.runner} fontFamily={FONT} fontSize={40} fill={C.ink} />
      </Rect>
      {Array.from({length: count}, (_, i) => (
        <Rect ref={jobs} width={box} height={box} radius={box / 6} fill={C.ink} x={jobPos(i)[0]} y={jobPos(i)[1]} scale={0} />
      ))}
      <Txt ref={caption} text={props.caption} fontFamily={FONT} fontSize={narrow ? 72 : 64} fill={C.ink} y={narrow ? runnerY + runnerSize / 2 + 110 : 300} textWrap width={1500} textAlign="center" opacity={0} />
    </>,
  );

  yield* caption().opacity(1, 0.6);
  for (const job of jobs) {
    yield* job.scale(1, 0.35);
    yield* waitFor(0.25);
  }
  if (props.caption2) yield* all(caption().text(props.caption2, 0.6), caption().fill(C.muted, 0.6));
  yield* holdFor(0.6 + count * 0.6 + 0.6);
});
