import {Rect, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, createRefArray, waitFor} from '@motion-canvas/core';
import {narrow, props} from '../config';
import {C, FONT, WEIGHT, holdFor, stage} from '../stage';

// Two cards side by side (stacked in portrait and square frames): `left` and `right` are {title, items}. The left one
// is the "before" (muted), the right one the "after" (accent). Items fill in alternately.
export default makeScene2D(function* (view) {
  const root = stage(view);
  const sides = [props.left ?? {title: '', items: []}, props.right ?? {title: '', items: []}] as {title: string; items: string[]}[];
  const caption = createRef<Txt>();
  const cards = createRefArray<Rect>();
  const itemTxts = sides.map(() => createRefArray<Txt>());
  const rows = Math.max(...sides.map((s) => s.items.length));
  const w = narrow ? 1500 : 760;
  const h = Math.min(narrow ? 800 : 640, 230 + rows * (narrow ? 100 : 74));
  const pos = (i: number): [number, number] => (narrow ? [0, (i - 0.5) * (h + 60) - 50] : [(i - 0.5) * (w + 60), -50]);

  root.add(
    <>
      {sides.map((side, i) => (
        <Rect ref={cards} x={pos(i)[0]} y={pos(i)[1]} width={w} height={h} radius={32} fill={C.card} stroke={i === 1 ? C.accent : C.line} lineWidth={i === 1 ? 6 : 3} opacity={0} layout direction="column" gap={20} padding={44}>
          <Txt text={side.title} fontFamily={FONT} fontSize={narrow ? 70 : 52} fontWeight={WEIGHT} fill={i === 1 ? C.ink : C.muted} />
          {side.items.map((item) => (
            <Txt ref={itemTxts[i]} text={`${i === 1 ? '✓' : '–'}  ${item}`} fontFamily={FONT} fontSize={narrow ? 60 : 42} fill={i === 1 ? C.ink : C.muted} opacity={0} />
          ))}
        </Rect>
      ))}
      <Txt ref={caption} text={props.caption ?? ''} fontFamily={FONT} fontSize={narrow ? 64 : 56} fontWeight={WEIGHT} fill={C.ink} y={narrow ? h + 330 : h / 2 + 90} textWrap width={1500} textAlign="center" opacity={0} />
    </>,
  );

  yield* all(...cards.map((c) => c.opacity(1, 0.6)));
  for (let r = 0; r < rows; r++) {
    for (let s = 0; s < 2; s++) if (itemTxts[s][r]) yield* itemTxts[s][r].opacity(1, 0.35);
    yield* waitFor(0.3);
  }
  yield* caption().opacity(1, 0.5);
  yield* holdFor(0.6 + rows * 1.3 + 0.5);
});
