import {Rect, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, createRefArray, waitFor} from '@motion-canvas/core';
import {props} from '../config';
import {C, FONT, holdFor, stage} from '../stage';

// One runner, one job at a time, a queue that only grows.
export default makeScene2D(function* (view) {
  const root = stage(view);
  const jobs = createRefArray<Rect>();
  const caption = createRef<Txt>();
  const count: number = props.count ?? 7;

  root.add(
    <>
      <Rect width={260} height={260} radius={32} lineWidth={8} stroke={C.ink} fill={C.card} x={520}>
        <Txt text={props.runner} fontFamily={FONT} fontSize={40} fill={C.ink} />
      </Rect>
      {Array.from({length: count}, (_, i) => (
        <Rect ref={jobs} width={120} height={120} radius={20} fill={C.ink} x={300 - i * 150} scale={0} />
      ))}
      <Txt ref={caption} text={props.caption} fontFamily={FONT} fontSize={64} fill={C.ink} y={300} opacity={0} />
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
