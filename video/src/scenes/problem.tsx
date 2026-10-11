import {Rect, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, createRefArray, waitFor} from '@motion-canvas/core';
import {FONT, INK, MUTED, PAPER} from '../theme';

// 6-16 s: one runner, one job at a time, a queue that only grows.
export default makeScene2D(function* (view) {
  view.fill(PAPER);
  const jobs = createRefArray<Rect>();
  const runner = createRef<Rect>();
  const caption = createRef<Txt>();

  view.add(
    <>
      <Rect ref={runner} width={260} height={260} radius={32} lineWidth={8} stroke={INK} x={520}>
        <Txt text="1 runner" fontFamily={FONT} fontSize={40} fill={INK} />
      </Rect>
      {Array.from({length: 7}, (_, i) => (
        <Rect ref={jobs} width={120} height={120} radius={20} fill={INK} x={300 - i * 150} scale={0} />
      ))}
      <Txt ref={caption} text="Your queue waits its turn." fontFamily={FONT} fontSize={64} fill={INK} y={300} opacity={0} />
    </>,
  );

  yield* caption().opacity(1, 0.6);
  for (const job of jobs) {
    yield* job.scale(1, 0.35);
    yield* waitFor(0.25);
  }
  yield* all(caption().text('A self-hosted runner does one job at a time.', 0.6), caption().fill(MUTED, 0.6));
  yield* waitFor(2.5);
});
