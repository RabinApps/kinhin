import {Circle, Rect, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, createRefArray, waitFor} from '@motion-canvas/core';
import {narrow, props} from '../config';
import {C, FONT, WEIGHT, holdFor, stage} from '../stage';

// A numbered list that fills in one step at a time: a title and `steps` (strings).
export default makeScene2D(function* (view) {
  const root = stage(view);
  const steps: string[] = props.steps ?? [];
  const rows = createRefArray<Rect>();
  const title = createRef<Txt>();
  const gap = Math.min(170, 760 / Math.max(1, steps.length));
  const y = (i: number) => (i - (steps.length - 1) / 2) * gap + 70;
  const w = narrow ? 1500 : 1400;

  root.add(
    <>
      <Txt ref={title} text={props.title ?? ''} fontFamily={FONT} fontSize={narrow ? 84 : 72} fontWeight={WEIGHT} fill={C.ink} y={-(steps.length * gap) / 2 - 120} textWrap width={1500} textAlign="center" opacity={0} />
      {steps.map((step, i) => (
        <Rect ref={rows} y={y(i)} x={0} width={w} height={gap - 24} radius={26} fill={C.card} stroke={C.line} lineWidth={2} opacity={0} layout alignItems="center" gap={32} padding={[0, 40]}>
          <Circle size={72} fill={C.ink} layout alignItems="center" justifyContent="center">
            <Txt text={String(i + 1)} fontFamily={FONT} fontSize={40} fontWeight={WEIGHT} fill={C.paper} />
          </Circle>
          <Txt text={step} fontFamily={FONT} fontSize={narrow ? 44 : 46} fill={C.ink} />
        </Rect>
      ))}
    </>,
  );

  yield* title().opacity(1, 0.6);
  for (const row of rows) {
    yield* row.opacity(1, 0.4);
    yield* waitFor(0.5);
  }
  yield* holdFor(0.6 + rows.length * 0.9);
});
