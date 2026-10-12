import {Circle, Txt, makeScene2D} from '@motion-canvas/2d';
import {createRef} from '@motion-canvas/core';
import {props} from '../config';
import {C, FONT, WEIGHT, holdFor, stage} from '../stage';

// The closing line, where to get it, and a row of facts.
export default makeScene2D(function* (view) {
  const root = stage(view);
  const line = createRef<Txt>();
  const url = createRef<Txt>();
  const facts = createRef<Txt>();

  root.add(
    <>
      <Circle size={90} lineWidth={8} stroke={C.ink} y={-230} />
      <Txt ref={line} text={props.line} fontFamily={FONT} fontSize={76} fontWeight={WEIGHT} fill={C.ink} y={-60} opacity={0} />
      <Txt ref={url} text={props.url ?? ''} fontFamily={FONT} fontSize={64} fill={C.ink} y={110} opacity={0} />
      <Txt ref={facts} text={(props.facts ?? []).join(' · ')} fontFamily={FONT} fontSize={36} fill={C.muted} y={200} opacity={0} />
    </>,
  );

  yield* line().opacity(1, 0.9);
  yield* url().opacity(1, 0.7);
  yield* facts().opacity(1, 0.7);
  yield* holdFor(2.3);
});
