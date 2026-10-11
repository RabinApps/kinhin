import {Rect, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, createRefArray, easeInOutCubic, easeOutCubic, waitFor} from '@motion-canvas/core';
import {content} from '../content';
import {timing} from '../timing';
import {BACKGROUND, FONT, INK, MUTED} from '../theme';

const JOBS = content.solution.jobs;
const INTRO = 0.6; // caption fades in
const STAGGER = 0.5; // seconds between lanes
const LANE = 0.6 + 1.2 + 0.3 + 0.4 + 0.5; // slide, run, check, hold, delete
const ROW = 190;
const CHIP_X = -600;
const CARD_X = 230;

// One job, one fresh VM, gone when the job is done: three lanes running side by side.
export default makeScene2D(function* (view) {
  view.fill(BACKGROUND);
  const chips = createRefArray<Rect>();
  const cards = createRefArray<Rect>();
  const bars = createRefArray<Rect>();
  const checks = createRefArray<Txt>();
  const caption = createRef<Txt>();
  const y = (i: number) => (i - (JOBS.length - 1) / 2) * ROW - 40;

  view.add(
    <>
      {JOBS.map((name, i) => (
        <Rect ref={chips} width={250} height={96} radius={22} fill={INK} x={CHIP_X} y={y(i)} opacity={0}>
          <Txt text={name} fontFamily={FONT} fontSize={34} fill="#ffffff" />
        </Rect>
      ))}
      {JOBS.map((_, i) => (
        <Rect ref={cards} width={640} height={130} radius={30} lineWidth={6} stroke={INK} fill="#ffffff" x={CARD_X} y={y(i)} scale={0.85} opacity={0}>
          <Txt text={content.solution.vm} fontFamily={FONT} fontSize={30} fill={MUTED} x={-190} y={-34} />
          <Rect width={300} height={14} radius={7} fill="#e3e6ec" x={-190} y={22} />
          <Rect ref={bars} width={0} height={14} radius={7} fill={INK} x={-340} offsetX={-1} y={22} />
          <Txt ref={checks} text="✓" fontFamily={FONT} fontSize={64} fontWeight={700} fill={INK} x={235} opacity={0} />
        </Rect>
      ))}
      <Txt ref={caption} text={content.solution.caption} fontFamily={FONT} fontSize={64} fill={INK} y={400} opacity={0} />
    </>,
  );

  function* lane(i: number) {
    yield* waitFor(i * STAGGER);
    yield* all(
      chips[i].opacity(1, 0.2),
      chips[i].x(CARD_X - 140, 0.6, easeInOutCubic),
      cards[i].opacity(1, 0.4),
      cards[i].scale(1, 0.5, easeOutCubic),
    );
    yield* all(chips[i].opacity(0, 0.2), bars[i].width(300, 1.2));
    yield* checks[i].opacity(1, 0.3);
    yield* waitFor(0.4);
    yield* all(cards[i].opacity(0, 0.5), cards[i].scale(0.85, 0.5, easeInOutCubic));
  }

  yield* caption().opacity(1, INTRO);
  yield* all(
    ...JOBS.map((_, i) => lane(i)),
    (function* () {
      yield* waitFor(STAGGER + 0.6 + 1.2); // the first VM has finished its job
      yield* all(caption().text(content.solution.done, 0.4), caption().fill(MUTED, 0.4));
    })(),
  );
  const animation = INTRO + (JOBS.length - 1) * STAGGER + LANE;
  yield* waitFor(Math.max(0.2, timing.solution - animation)); // then hold for the voice
});
