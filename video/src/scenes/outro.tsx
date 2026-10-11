import {Circle, Txt, makeScene2D} from '@motion-canvas/2d';
import {createRef, waitFor} from '@motion-canvas/core';
import {content} from '../content';
import {timing} from '../timing';
import {BACKGROUND, FONT, INK, MUTED, PAPER} from '../theme';

// 62-70 s: the line the README ends on, then where to get it.
export default makeScene2D(function* (view) {
  view.fill(BACKGROUND);
  const line = createRef<Txt>();
  const url = createRef<Txt>();
  const facts = createRef<Txt>();

  view.add(
    <>
      <Circle size={90} lineWidth={8} stroke={INK} y={-230} />
      <Txt ref={line} text={content.outro.line} fontFamily={FONT} fontSize={76} fontWeight={600} fill={INK} y={-60} opacity={0} />
      <Txt ref={url} text={content.outro.url} fontFamily={FONT} fontSize={64} fill={INK} y={110} opacity={0} />
      <Txt ref={facts} text={content.outro.facts.join(' · ')} fontFamily={FONT} fontSize={36} fill={MUTED} y={200} opacity={0} />
    </>,
  );

  yield* line().opacity(1, 0.9);
  yield* url().opacity(1, 0.7);
  yield* facts().opacity(1, 0.7);
  yield* waitFor(timing.outro - 2.3); // 2.3 s of animation, then hold for the voice
});
