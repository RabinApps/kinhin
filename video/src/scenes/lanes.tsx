import {Circle, Line, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, createRefArray, waitFor} from '@motion-canvas/core';
import {content} from '../content';
import {FONT, INK, MUTED, PAPER} from '../theme';

const FORGES = content.lanes.forges;
const RUNTIMES = content.lanes.runtimes;

// 40-52 s: four forges, three runtimes, one fleet.
export default makeScene2D(function* (view) {
  view.fill(PAPER);
  const forges = createRefArray<Txt>();
  const runtimes = createRefArray<Txt>();
  const lines = createRefArray<Line>();
  const hub = createRef<Circle>();
  const caption = createRef<Txt>();
  const note = createRef<Txt>();

  const forgeY = (i: number) => (i - (FORGES.length - 1) / 2) * 130;
  const runtimeY = (i: number) => (i - (RUNTIMES.length - 1) / 2) * 170;

  view.add(
    <>
      <Circle ref={hub} size={120} lineWidth={10} stroke={INK} opacity={0} />
      {FORGES.map((name, i) => (
        <Txt ref={forges} text={name} fontFamily={FONT} fontSize={52} fill={INK} x={-640} y={forgeY(i)} opacity={0} />
      ))}
      {RUNTIMES.map((name, i) => (
        <Txt ref={runtimes} text={name} fontFamily={FONT} fontSize={44} fill={INK} x={640} y={runtimeY(i)} opacity={0} />
      ))}
      {FORGES.flatMap((_, f) =>
        RUNTIMES.map((__, r) => (
          <Line ref={lines} points={[[-480, forgeY(f)], [-60, 0], [60, 0], [380, runtimeY(r)]]} radius={80} lineWidth={2} stroke={MUTED} end={0} opacity={0.5} />
        )),
      )}
      <Txt ref={caption} text={content.lanes.caption} fontFamily={FONT} fontSize={60} fontWeight={600} fill={INK} y={420} opacity={0} />
      <Txt ref={note} text={content.lanes.note} fontFamily={FONT} fontSize={34} fill={MUTED} y={490} opacity={0} />
    </>,
  );

  yield* all(...forges.map(t => t.opacity(1, 0.6)), ...runtimes.map(t => t.opacity(1, 0.6)), hub().opacity(1, 0.6));
  yield* all(...lines.map(l => l.end(1, 1.2)));
  yield* caption().opacity(1, 0.6);
  yield* note().opacity(1, 0.6);
  yield* waitFor(3);
});
