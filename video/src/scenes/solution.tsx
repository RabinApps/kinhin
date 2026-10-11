import {Rect, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, easeInOutCubic, waitFor} from '@motion-canvas/core';
import {content} from '../content';
import {timing} from '../timing';
import {FONT, INK, MUTED, PAPER} from '../theme';

const CYCLES = 3;
const CYCLE = 2.1; // seconds per job: arrive, boot a VM, run, delete
const INTRO = 0.6;

// One job, one fresh VM, gone when the job is done, three times over.
export default makeScene2D(function* (view) {
  view.fill(PAPER);
  const job = createRef<Rect>();
  const vm = createRef<Rect>();
  const bar = createRef<Rect>();
  const caption = createRef<Txt>();

  view.add(
    <>
      <Rect ref={job} width={120} height={120} radius={20} fill={INK} x={-640} opacity={0} />
      <Rect ref={vm} width={320} height={320} radius={44} lineWidth={8} stroke={INK} x={140} scale={0} opacity={0}>
        <Txt text={content.solution.vm} fontFamily={FONT} fontSize={36} fill={MUTED} y={-90} />
        <Rect ref={bar} width={0} height={18} radius={9} fill={INK} x={-110} offsetX={-1} y={50} />
      </Rect>
      <Txt ref={caption} text={content.solution.caption} fontFamily={FONT} fontSize={64} fill={INK} y={300} opacity={0} />
    </>,
  );

  yield* caption().opacity(1, INTRO);
  for (let i = 0; i < CYCLES; i++) {
    job().x(-640);
    bar().width(0);
    yield* job().opacity(1, 0.2);
    yield* all(job().x(-120, 0.5, easeInOutCubic), vm().opacity(1, 0.3), vm().scale(1, 0.4, easeInOutCubic));
    yield* all(job().opacity(0, 0.2), bar().width(220, 0.8));
    if (i === 0) yield* all(caption().text(content.solution.done, 0.4), caption().fill(MUTED, 0.4));
    yield* all(vm().scale(0, 0.4, easeInOutCubic), vm().opacity(0, 0.4));
  }
  const animation = INTRO + CYCLES * (0.2 + 0.5 + 0.8 + 0.4) + 0.4; // the +0.4 is the caption change
  yield* waitFor(Math.max(0.2, timing.solution - animation)); // then hold for the voice
});
