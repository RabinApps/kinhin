import {Rect, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, createRefArray, createSignal, waitFor} from '@motion-canvas/core';
import {fit, format, narrow, props} from '../config';
import {C, FONT, WEIGHT, holdFor, stage} from '../stage';

// Big numbers that count up: each item is {value, label}. A value like "75%", "4", "1.5x" or "$12" counts from zero to
// its number and keeps its prefix and suffix. Wide frames: a row. Portrait and square frames: a column.
export default makeScene2D(function* (view) {
  const root = stage(view);
  const items: {value: string; label: string}[] = props.items ?? [];
  const caption = createRef<Txt>();
  const cards = createRefArray<Rect>();
  const parts = items.map((item) => {
    const m = String(item.value).match(/^(\D*)([\d.,]+)(.*)$/);
    return {prefix: m?.[1] ?? '', target: m ? parseFloat(m[2].replace(/,/g, '')) : 0, decimals: m?.[2].includes('.') ? (m[2].split('.')[1] ?? '').length : 0, suffix: m?.[3] ?? '', raw: String(item.value), numeric: !!m};
  });
  const counters = parts.map(() => createSignal(0));
  const text = (i: number) => (parts[i].numeric ? `${parts[i].prefix}${counters[i]().toFixed(parts[i].decimals)}${parts[i].suffix}` : parts[i].raw);
  const n = items.length;
  // Narrow frames stack the numbers; the spacing and the caption follow the frame's real height.
  const halfHeight = format.height / fit / 2;
  const spacing = Math.min(330, (halfHeight * 2 - 460) / Math.max(1, n));
  const captionY = narrow ? Math.min(700, halfHeight - 150) : 330;
  const pos = (i: number): [number, number] => (narrow ? [0, (i - (n - 1) / 2) * spacing - 60] : [(i - (n - 1) / 2) * Math.min(520, 1500 / n), -40]);

  root.add(
    <>
      {items.map((item, i) => (
        <Rect ref={cards} x={pos(i)[0]} y={pos(i)[1]} width={460} height={280} opacity={0} scale={0.9} layout direction="column" alignItems="center" justifyContent="center" gap={10}>
          <Txt text={() => text(i)} fontFamily={FONT} fontSize={narrow ? 150 : 150 - Math.max(0, n - 3) * 20} fontWeight={WEIGHT} fill={C.accent === C.ink ? C.ink : C.accent} />
          <Txt text={item.label} fontFamily={FONT} fontSize={40} fill={C.muted} />
        </Rect>
      ))}
      <Txt ref={caption} text={props.caption ?? ''} fontFamily={FONT} fontSize={narrow ? 64 : 60} fontWeight={WEIGHT} fill={C.ink} y={captionY} textWrap width={1500} textAlign="center" opacity={0} />
    </>,
  );

  yield* waitFor(0.3);
  yield* all(
    ...cards.map((c, i) => all(c.opacity(1, 0.5), c.scale(1, 0.5))),
    ...counters.map((s, i) => s(parts[i].target, 1.6)),
  );
  yield* caption().opacity(1, 0.6);
  yield* holdFor(0.3 + 1.6 + 0.6);
});
