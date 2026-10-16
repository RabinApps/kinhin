import {Rect, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, createRefArray, easeInOutCubic, easeOutCubic, waitFor} from '@motion-canvas/core';
import {length, props} from '../config';
import {C, FONT, TYPE, WEIGHT, holdFor, stage} from '../stage';

const INTRO = 0.6; // the caption fades in
const STAGGER = 0.5; // seconds between lanes
const LANE = 0.6 + 1.2 + 0.3 + 0.4 + 0.5; // slide, run, check, hold, delete
const ROW = 190;
const CHIP_X = -600;
const CARD_X = 230;
const CARD_W = 640;
const PAD = 60; // inside the card's border, on the left
const BAR_W = 360;

// Items each flow into their own fresh card, run, finish and vanish, side by side, for as long as the voice lasts.
export default makeScene2D(function* (view) {
  const root = stage(view);
  const items: string[] = props.items ?? ['one', 'two', 'three'];
  const chips = createRefArray<Rect>();
  const cards = createRefArray<Rect>();
  const bars = createRefArray<Rect>();
  const checks = createRefArray<Txt>();
  const caption = createRef<Txt>();
  const y = (i: number) => (i - (items.length - 1) / 2) * ROW - 40;

  root.add(
    <>
      {items.map((name, i) => (
        <Rect ref={chips} width={250} height={96} radius={22} fill={C.ink} x={CHIP_X} y={y(i)} opacity={0}>
          <Txt text={name} fontFamily={FONT} fontSize={34} fill={C.paper} />
        </Rect>
      ))}
      {items.map((_, i) => (
        <Rect ref={cards} width={CARD_W} height={130} radius={30} lineWidth={6} stroke={C.ink} fill={C.card} x={CARD_X} y={y(i)} scale={0.85} opacity={0}>
          {/* offsetX -1 anchors each piece's left edge, so the label, track and bar share one line inside the border */}
          <Txt text={props.card} fontFamily={FONT} fontSize={30} fill={C.muted} x={-CARD_W / 2 + PAD} offsetX={-1} y={-34} />
          <Rect width={BAR_W} height={14} radius={7} fill={C.track} x={-CARD_W / 2 + PAD} offsetX={-1} y={22} />
          <Rect ref={bars} width={0} height={14} radius={7} fill={C.accent} x={-CARD_W / 2 + PAD} offsetX={-1} y={22} />
          <Txt ref={checks} text="✓" fontFamily={FONT} fontSize={64} fontWeight={WEIGHT} fill={C.accent} x={CARD_W / 2 - PAD} offsetX={1} opacity={0} />
        </Rect>
      ))}
      <Txt ref={caption} text={props.caption} fontFamily={FONT} fontSize={TYPE.caption} fill={C.ink} y={400} opacity={0} />
    </>,
  );

  function* lane(i: number) {
    chips[i].x(CHIP_X);
    chips[i].opacity(0);
    cards[i].opacity(0);
    cards[i].scale(0.85);
    bars[i].width(0);
    checks[i].opacity(0);
    yield* all(chips[i].opacity(1, 0.2), chips[i].x(CARD_X - 140, 0.6, easeInOutCubic), cards[i].opacity(1, 0.4), cards[i].scale(1, 0.5, easeOutCubic));
    yield* all(chips[i].opacity(0, 0.2), bars[i].width(BAR_W, 1.2));
    yield* checks[i].opacity(1, 0.3);
    yield* waitFor(0.4);
    yield* all(cards[i].opacity(0, 0.5), cards[i].scale(0.85, 0.5, easeInOutCubic));
  }

  // Each lane runs on its own clock: it starts STAGGER after the one before, then repeats. No round waits for the
  // slowest lane to clear, so a card is always on screen (no empty frame between rounds).
  const rounds = Math.max(1, Math.floor((length - INTRO - (items.length - 1) * STAGGER) / LANE));
  function* lanes(i: number) {
    yield* waitFor(i * STAGGER);
    for (let r = 0; r < rounds; r++) yield* lane(i);
  }

  yield* caption().opacity(1, INTRO);
  yield* all(
    ...items.map((_, i) => lanes(i)),
    (function* () {
      if (!props.done) return;
      yield* waitFor(STAGGER + 0.6 + 1.2); // the first card has finished
      yield* all(caption().text(props.done, 0.4), caption().fill(C.muted, 0.4));
    })(),
  );
  yield* holdFor(INTRO + (items.length - 1) * STAGGER + rounds * LANE);
});
