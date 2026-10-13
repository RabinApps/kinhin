import {Circle, Txt, makeScene2D} from '@motion-canvas/2d';
import {createRef} from '@motion-canvas/core';
import {props} from '../config';
import {C, FONT, WEIGHT, fitText, holdFor, stage} from '../stage';

// The closing line, where to get it, and a row of facts. Each block wraps inside 1500 design pixels and shrinks to fit.
export default makeScene2D(function* (view) {
  const root = stage(view);
  const line = createRef<Txt>();
  const url = createRef<Txt>();
  const facts = createRef<Txt>();
  const factLine = (props.facts ?? []).join(' · ');

  root.add(
    <>
      <Circle size={90} lineWidth={8} stroke={C.ink} y={-230} />
      <Txt ref={line} text={props.line} fontFamily={FONT} fontSize={fitText(props.line ?? '', 76, 1500, 2)} fontWeight={WEIGHT} fill={C.ink} textWrap width={1500} textAlign="center" y={-60} opacity={0} />
      <Txt ref={url} text={props.url ?? ''} fontFamily={FONT} fontSize={fitText(props.url ?? '', 64, 1500)} fill={C.ink} textWrap width={1500} textAlign="center" y={110} opacity={0} />
      <Txt ref={facts} text={factLine} fontFamily={FONT} fontSize={fitText(factLine, 36, 1600)} fill={C.muted} textWrap width={1600} textAlign="center" y={200} opacity={0} />
    </>,
  );

  yield* line().opacity(1, 0.9);
  yield* url().opacity(1, 0.7);
  yield* facts().opacity(1, 0.7);
  yield* holdFor(2.3);
});
