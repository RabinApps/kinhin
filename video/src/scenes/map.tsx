import {Circle, Line, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, createRefArray} from '@motion-canvas/core';
import {props} from '../config';
import {C, FONT, WEIGHT, holdFor, stage} from '../stage';

// Several things on the left, several on the right, one hub between them.
export default makeScene2D(function* (view) {
  const root = stage(view);
  const left: string[] = props.left ?? [];
  const right: string[] = props.right ?? [];
  const lefts = createRefArray<Txt>();
  const rights = createRefArray<Txt>();
  const lines = createRefArray<Line>();
  const caption = createRef<Txt>();
  const note = createRef<Txt>();
  const hub = createRef<Circle>();
  const leftY = (i: number) => (i - (left.length - 1) / 2) * Math.min(130, 520 / left.length);
  const rightY = (i: number) => (i - (right.length - 1) / 2) * Math.min(170, 520 / right.length);

  root.add(
    <>
      <Circle ref={hub} size={120} lineWidth={10} stroke={C.ink} opacity={0} />
      {left.map((name, i) => (
        <Txt ref={lefts} text={name} fontFamily={FONT} fontSize={52} fill={C.ink} x={-380} offsetX={1} y={leftY(i)} opacity={0} />
      ))}
      {right.map((name, i) => (
        <Txt ref={rights} text={name} fontFamily={FONT} fontSize={40} fill={C.ink} x={380} offsetX={-1} y={rightY(i)} opacity={0} />
      ))}
      {left.flatMap((_, l) =>
        right.map((__, r) => (
          <Line ref={lines} points={[[-350, leftY(l)], [-60, 0], [60, 0], [350, rightY(r)]]} radius={80} lineWidth={2} stroke={C.line} end={0} opacity={0.5} />
        )),
      )}
      <Txt ref={caption} text={props.caption ?? ''} fontFamily={FONT} fontSize={60} fontWeight={WEIGHT} fill={C.ink} y={420} opacity={0} />
      <Txt ref={note} text={props.note ?? ''} fontFamily={FONT} fontSize={34} fill={C.muted} y={490} opacity={0} />
    </>,
  );

  yield* all(...lefts.map((t) => t.opacity(1, 0.6)), ...rights.map((t) => t.opacity(1, 0.6)), hub().opacity(1, 0.6));
  yield* all(...lines.map((l) => l.end(1, 1.2)));
  yield* caption().opacity(1, 0.6);
  yield* note().opacity(1, 0.6);
  yield* holdFor(3);
});
