import {Rect, Txt, makeScene2D} from '@motion-canvas/2d';
import {all, createRef, createRefArray, waitFor} from '@motion-canvas/core';
import {narrow, props, theme} from '../config';
import {C, FONT, TYPE, holdFor, stage} from '../stage';

const MONO = `${theme.font.mono ?? 'DejaVu Sans Mono'}, "SF Mono", Menlo, Consolas, monospace`;

// A code or terminal block that types itself line by line: `lines` (strings), an optional `label` on the title bar and
// a `caption` under it. Lines starting with "$" or ">" are commands (accent colour), "#" or "//" are comments (muted).
export default makeScene2D(function* (view) {
  const root = stage(view);
  const lines: string[] = props.lines ?? [];
  const texts = createRefArray<Txt>();
  const caption = createRef<Txt>();
  const size = narrow ? 44 : 40;
  const pitch = size * 1.6;
  const width = narrow ? 1560 : 1500;
  const height = lines.length * pitch + 150;
  const color = (line: string) => (/^\s*(\$|>)/.test(line) ? C.accent : /^\s*(#|\/\/)/.test(line) ? C.muted : C.ink);

  root.add(
    <>
      <Rect width={width} height={height} radius={32} fill={C.card} stroke={C.line} lineWidth={3} y={-30} opacity={1}>
        <Rect width={width} height={64} y={-height / 2 + 32} fill={C.track} radius={[32, 32, 0, 0]} />
        <Txt text={props.label ?? ''} fontFamily={FONT} fontSize={28} fill={C.muted} y={-height / 2 + 32} />
        {lines.map((line, i) => (
          <Txt ref={texts} text="" fontFamily={MONO} fontSize={size} fill={color(line)} x={-width / 2 + 56} y={-height / 2 + 120 + i * pitch} offsetX={-1} />
        ))}
      </Rect>
      <Txt ref={caption} text={props.caption ?? ''} fontFamily={FONT} fontSize={TYPE.caption} fill={C.ink} y={height / 2 + 110} textWrap width={1500} textAlign="center" opacity={0} />
    </>,
  );

  yield* waitFor(0.4);
  for (const [i, line] of lines.entries()) {
    yield* texts[i].text(line, Math.max(0.5, line.length * 0.035));
    yield* waitFor(0.25);
  }
  yield* caption().opacity(1, 0.5);
  yield* holdFor(0.4 + lines.reduce((a, l) => a + Math.max(0.5, l.length * 0.035) + 0.25, 0) + 0.5);
});
