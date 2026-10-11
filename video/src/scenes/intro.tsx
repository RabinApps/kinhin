import {Circle, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, waitFor} from '@motion-canvas/core';
import {content} from '../content';
import {timing} from '../timing';
import {BACKGROUND, FONT, INK, MUTED, PAPER} from '../theme';

// 0-6 s: the ring draws itself, then the tagline.
export default makeScene2D(function* (view) {
  view.fill(BACKGROUND);
  const ring = createRef<Circle>();
  const title = createRef<Txt>();
  const sub = createRef<Txt>();

  view.add(
    <>
      <Circle ref={ring} size={260} lineWidth={14} stroke={INK} startAngle={-90} endAngle={-90} y={-60} />
      <Txt ref={title} text={content.intro.title} fontFamily={FONT} fontSize={96} fontWeight={600} fill={INK} y={170} opacity={0} />
      <Txt ref={sub} text={content.intro.subtitle} fontFamily={FONT} fontSize={40} fill={MUTED} y={250} opacity={0} />
    </>,
  );

  yield* waitFor(0.4);
  yield* ring().endAngle(270, 1.8);
  yield* all(title().opacity(1, 0.8), title().y(160, 0.8));
  yield* sub().opacity(1, 0.6);
  yield* waitFor(timing.intro - 3.6); // 3.6 s of animation, then hold for the voice
});
