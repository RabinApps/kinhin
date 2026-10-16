import {Circle, Txt, makeScene2D} from '@motion-canvas/2d';
import {createRef} from '@motion-canvas/core';
import {narrow, props} from '../config';
import {C, FONT, TYPE, WEIGHT, fitText, holdFor, narrowBox, stage} from '../stage';

// The closing line, where to get it, and a row of facts. Each block wraps inside its box and shrinks to fit. The outro is
// 1300 design pixels wide in a narrow frame (SCENE_TYPES in shared/resolve.mjs), so its boxes are narrower there.
export default makeScene2D(function* (view) {
  const root = stage(view);
  const line = createRef<Txt>();
  const url = createRef<Txt>();
  const facts = createRef<Txt>();
  const factLine = (props.facts ?? []).join(' · ');
  const lineW = narrow ? narrowBox('outro') : 1500;
  const factsW = narrow ? narrowBox('outro') : 1600;

  root.add(
    <>
      <Circle size={90} lineWidth={8} stroke={C.ink} y={-230} />
      <Txt ref={line} text={props.line} fontFamily={FONT} fontSize={fitText(props.line ?? '', TYPE.headline, lineW, 2)} fontWeight={WEIGHT} fill={C.ink} textWrap width={lineW} textAlign="center" y={-60} opacity={0} />
      <Txt ref={url} text={props.url ?? ''} fontFamily={FONT} fontSize={fitText(props.url ?? '', 64, lineW)} fill={C.ink} textWrap width={lineW} textAlign="center" y={110} opacity={0} />
      <Txt ref={facts} text={factLine} fontFamily={FONT} fontSize={fitText(factLine, 36, factsW)} fill={C.muted} textWrap width={factsW} textAlign="center" y={200} opacity={0} />
    </>,
  );

  yield* line().opacity(1, 0.9);
  yield* url().opacity(1, 0.7);
  yield* facts().opacity(1, 0.7);
  yield* holdFor(2.3);
});
