import {Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, waitFor} from '@motion-canvas/core';
import {narrow, props} from '../config';
import {C, FONT, WEIGHT, holdFor, stage} from '../stage';

// One big sentence, with an optional line under it.
export default makeScene2D(function* (view) {
  const root = stage(view);
  const text = createRef<Txt>();
  const sub = createRef<Txt>();
  root.add(
    <>
      <Txt ref={text} text={props.text} fontFamily={FONT} fontSize={props.size ?? (narrow ? 112 : 92)} fontWeight={WEIGHT} fill={C.ink} textWrap width={narrow ? 1300 : 1500} textAlign="center" y={-20} opacity={0} />
      <Txt ref={sub} text={props.sub ?? ''} fontFamily={FONT} fontSize={42} fill={C.muted} y={190} opacity={0} />
    </>,
  );
  yield* waitFor(0.3);
  yield* all(text().opacity(1, 0.8), text().y(-30, 0.8));
  yield* sub().opacity(1, 0.6);
  yield* holdFor(1.7);
});
