import {Rect, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, createRefArray, waitFor} from '@motion-canvas/core';
import {content} from '../content';
import {timing} from '../timing';
import {BACKGROUND, FONT, INK, MUTED, PAPER} from '../theme';

// 6-16 s: one runner, one job at a time, a queue that only grows.
export default makeScene2D(function* (view) {
  view.fill(BACKGROUND);
  const jobs = createRefArray<Rect>();
  const runner = createRef<Rect>();
  const caption = createRef<Txt>();

  view.add(
    <>
      <Rect ref={runner} width={260} height={260} radius={32} lineWidth={8} stroke={INK} x={520}>
        <Txt text={content.problem.runner} fontFamily={FONT} fontSize={40} fill={INK} />
      </Rect>
      {Array.from({length: content.problem.jobsInQueue}, (_, i) => (
        <Rect ref={jobs} width={120} height={120} radius={20} fill={INK} x={300 - i * 150} scale={0} />
      ))}
      <Txt ref={caption} text={content.problem.queueCaption} fontFamily={FONT} fontSize={64} fill={INK} y={300} opacity={0} />
    </>,
  );

  yield* caption().opacity(1, 0.6);
  for (const job of jobs) {
    yield* job.scale(1, 0.35);
    yield* waitFor(0.25);
  }
  yield* all(caption().text(content.problem.limitCaption, 0.6), caption().fill(MUTED, 0.6));
  yield* waitFor(timing.problem - 5.4); // 5.4 s of animation, then hold for the voice
});
