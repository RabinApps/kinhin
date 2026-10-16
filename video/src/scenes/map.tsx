import {Circle, Img, Line, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, createRefArray} from '@motion-canvas/core';
import {narrow, props} from '../config';
import {C, FONT, TYPE, WEIGHT, holdFor, stage} from '../stage';

// Forge logos: single-colour SVGs in src/assets/forges (Simple Icons, CC0), named after their slug.
const logoFiles = import.meta.glob('../assets/forges/*.svg', {eager: true, query: '?url', import: 'default'}) as Record<string, string>;
const logo = (slug: string): string => {
  const url = logoFiles[`../assets/forges/${slug}.svg`];
  if (!url) throw new Error(`no logo "${slug}" in src/assets/forges/`);
  return url;
};

// Several things on one side, several on the other, one hub between them. Wide frames: left, hub, right.
// Portrait and square frames: a row on top, the hub, a row below. `logos` gives a logo slug for each left name; `soon`
// is a row of faded logos for forges that are coming soon, with its own caption.
export default makeScene2D(function* (view) {
  const root = stage(view);
  const left: string[] = props.left ?? [];
  const right: string[] = props.right ?? [];
  const logos: string[] = props.logos ?? [];
  const soon: {logos: string[]; caption: string} | undefined = props.soon;
  const lefts = createRefArray<Txt>();
  const rights = createRefArray<Txt>();
  const leftLogos = createRefArray<Img>();
  const soonLogos = createRefArray<Img>();
  const lines = createRefArray<Line>();
  const caption = createRef<Txt>();
  const note = createRef<Txt>();
  const soonCaption = createRef<Txt>();
  const hub = createRef<Circle>();

  // Where each item sits, and where its line meets the hub.
  const rowX = (i: number, n: number, span: number) => (i - (n - 1) / 2) * Math.min(span / n, 520);
  const leftPos = (i: number): [number, number] => (narrow ? [rowX(i, left.length, 1560), -420] : [-380, (i - (left.length - 1) / 2) * Math.min(130, 520 / left.length)]);
  const rightPos = (i: number): [number, number] => (narrow ? [rowX(i, right.length, 1560), 420] : [380, (i - (right.length - 1) / 2) * Math.min(170, 520 / right.length)]);
  const path = (l: [number, number], r: [number, number]): [number, number][] =>
    narrow ? [[l[0], l[1] + 50], [l[0] * 0.3, -120], [0, -70], [0, 70], [r[0] * 0.3, 120], [r[0], r[1] - 50]] : [[l[0] + 30, l[1]], [-60, 0], [60, 0], [r[0] - 30, r[1]]];
  // Wide: logo, then the name left-aligned beside it. Portrait: logo above the name, centred.
  const logoPos = (i: number): [number, number] => (narrow ? [leftPos(i)[0], leftPos(i)[1] - 90] : [-640, leftPos(i)[1]]);
  const namePos = (i: number): [number, number] => (narrow ? leftPos(i) : [-580, leftPos(i)[1]]);
  const soonY = narrow ? 520 : 380;
  const soonX = (i: number, n: number) => (narrow ? rowX(i, n, 1560) : (i - (n - 1) / 2) * 420);

  root.add(
    <>
      <Circle ref={hub} size={120} lineWidth={10} stroke={C.ink} opacity={0} />
      {left.map((name, i) => (
        <Txt ref={lefts} text={name} fontFamily={FONT} fontSize={TYPE.label} fill={C.ink} x={namePos(i)[0]} y={namePos(i)[1]} offsetX={narrow ? 0 : -1} opacity={0} />
      ))}
      {logos.map((slug, i) => (
        <Img ref={leftLogos} src={logo(slug)} width={narrow ? 84 : 56} height={narrow ? 84 : 56} x={logoPos(i)[0]} y={logoPos(i)[1]} opacity={0} />
      ))}
      {right.map((name, i) => (
        <Txt ref={rights} text={name} fontFamily={FONT} fontSize={TYPE.label} fill={C.ink} x={rightPos(i)[0]} y={rightPos(i)[1]} offsetX={narrow ? 0 : -1} opacity={0} />
      ))}
      {left.flatMap((_, l) =>
        right.map((__, r) => <Line ref={lines} points={path(leftPos(l), rightPos(r))} radius={80} lineWidth={2} stroke={C.line} end={0} opacity={0.5} />),
      )}
      {soon?.logos.map((slug, i) => (
        <Img ref={soonLogos} src={logo(slug)} width={narrow ? 72 : 64} height={narrow ? 72 : 64} x={soonX(i, soon.logos.length)} y={soonY} opacity={0} />
      ))}
      <Txt ref={soonCaption} text={soon?.caption ?? ''} fontFamily={FONT} fontSize={TYPE.note} fill={C.muted} y={narrow ? soonY + 70 : soonY + 60} textWrap width={1500} textAlign="center" opacity={0} />
      <Txt ref={caption} text={props.caption ?? ''} fontFamily={FONT} fontSize={TYPE.caption} fontWeight={WEIGHT} fill={C.ink} y={narrow ? 660 : -420} textWrap width={1500} textAlign="center" opacity={0} />
      <Txt ref={note} text={props.note ?? ''} fontFamily={FONT} fontSize={TYPE.note} fill={C.muted} y={narrow ? 750 : -330} textWrap width={1500} textAlign="center" opacity={0} />
    </>,
  );

  yield* all(
    ...lefts.map((t) => t.opacity(1, 0.6)),
    ...leftLogos.map((t) => t.opacity(1, 0.6)),
    ...rights.map((t) => t.opacity(1, 0.6)),
    hub().opacity(1, 0.6),
  );
  yield* all(...lines.map((l) => l.end(1, 1.2)));
  yield* caption().opacity(1, 0.6);
  yield* note().opacity(1, 0.6);
  if (soon) {
    yield* all(...soonLogos.map((t) => t.opacity(0.35, 0.8)), soonCaption().opacity(1, 0.8));
  }
  yield* holdFor(3);
});
