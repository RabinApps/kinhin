import {Circle, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, waitFor} from '@motion-canvas/core';
import {narrow, props} from '../config';
import {C, FONT, WEIGHT, fitText, holdFor, stage} from '../stage';

// A mark (the ring draws itself), a title and a subtitle. Each is one line, shrunk to fit its box: 1600 design pixels wide,
// or 1000 in a narrow frame (the title scene is 1100 design pixels wide there, see SCENE_TYPES in shared/resolve.mjs).
export default makeScene2D(function* (view) {
  const root = stage(view);
  const ring = createRef<Circle>();
  const title = createRef<Txt>();
  const sub = createRef<Txt>();
  const mark = props.mark ?? 'ring';
  const boxW = narrow ? 1000 : 1600;

  root.add(
    <>
      {mark === 'ring' ? <Circle ref={ring} size={260} lineWidth={14} stroke={C.ink} startAngle={-90} endAngle={-90} y={-60} /> : null}
      <Txt ref={title} text={props.title} fontFamily={FONT} fontSize={fitText(props.title ?? '', 96, boxW)} fontWeight={WEIGHT} fill={C.ink} textWrap width={boxW} textAlign="center" y={mark === 'ring' ? 170 : 0} opacity={0} />
      <Txt ref={sub} text={props.subtitle ?? ''} fontFamily={FONT} fontSize={fitText(props.subtitle ?? '', 40, boxW)} fill={C.muted} textWrap width={boxW} textAlign="center" y={mark === 'ring' ? 250 : 80} opacity={0} />
    </>,
  );

  yield* waitFor(0.4);
  if (mark === 'ring') yield* ring().endAngle(270, 1.8);
  yield* all(title().opacity(1, 0.8), title().y(title().y() - 10, 0.8));
  yield* sub().opacity(1, 0.6);
  yield* holdFor(mark === 'ring' ? 3.6 : 1.8);
});
