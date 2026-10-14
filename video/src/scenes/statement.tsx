import {Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, waitFor} from '@motion-canvas/core';
import {narrow, props} from '../config';
import {C, FONT, WEIGHT, fitText, holdFor, narrowBox, stage} from '../stage';

// One big sentence, with an optional line under it.
export default makeScene2D(function* (view) {
  const root = stage(view);
  const text = createRef<Txt>();
  const sub = createRef<Txt>();
  const boxW = narrow ? narrowBox('statement') : 1500;
  root.add(
    <>
      <Txt ref={text} text={props.text} fontFamily={FONT} fontSize={fitText(props.text ?? '', props.size ?? (narrow ? 112 : 92), boxW, 2)} fontWeight={WEIGHT} fill={C.ink} textWrap width={boxW} textAlign="center" y={-20} opacity={0} />
      <Txt ref={sub} text={props.sub ?? ''} fontFamily={FONT} fontSize={fitText(props.sub ?? '', 42, boxW, 2)} fill={C.muted} textWrap width={boxW} textAlign="center" y={190} opacity={0} />
    </>,
  );
  yield* waitFor(0.3);
  yield* all(text().opacity(1, 0.8), text().y(-30, 0.8));
  yield* sub().opacity(1, 0.6);
  yield* holdFor(1.7);
});
