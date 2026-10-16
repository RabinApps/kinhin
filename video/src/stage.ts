import {Gradient, Node, type View2D} from '@motion-canvas/2d';
import {waitFor} from '@motion-canvas/core';
import {SCENE_TYPES} from '../shared/resolve.mjs';
import {fit, length, theme} from './config';

export const C = theme.colors;
export const FONT = theme.font.css;
export const WEIGHT = theme.font.weight ?? 600;

/**
 * The type scale every canvas scene uses, in design pixels. One size per role, so a caption in one scene is the same size
 * as a caption in another: display (title), statement (one big sentence), headline (section and step titles, closing line),
 * caption (the line under a diagram or a block), label (the names in a row or a card), note (the smallest line on a scene).
 */
export const TYPE = {display: 96, statement: 92, headline: 72, caption: 60, label: 46, note: 34} as const;

/**
 * Paints the theme's backdrop and returns the node scenes add their content to. Content is laid out in a
 * 1920x1080 design space and scaled to fit whatever format is being rendered.
 */
export function stage(view: View2D): Node {
  const h = view.height();
  view.fill(
    new Gradient({
      type: 'linear',
      from: [0, -h / 2],
      to: [0, h / 2],
      stops: [
        {offset: 0, color: theme.background.from},
        {offset: 1, color: theme.background.to},
      ],
    }),
  );
  const root = new Node({scale: fit});
  view.add(root);
  return root;
}

/**
 * The box width a text gets in a narrow frame: 92% of the scene's own design width (SCENE_TYPES), since a narrow frame scales
 * the scene so that width fills the frame. Tying it to designWidth keeps the box inside the frame if that width changes.
 */
export const narrowBox = (sceneType: keyof typeof SCENE_TYPES): number => Math.round(SCENE_TYPES[sceneType].designWidth * 0.92);

/**
 * The font size that fits `text` in `maxLines` lines of `width` design pixels: `size` when it already fits, smaller when it
 * does not. Text is laid out with textWrap, so words wrap, and this keeps the block inside its box. The glyph width is an
 * estimate (0.6 em, wider than most sans faces), so a line never runs past the edge.
 */
export function fitText(text: string, size: number, width: number, maxLines = 1): number {
  const glyph = 0.6;
  return Math.floor(Math.min(size, (width * maxLines) / (Math.max(1, text.length) * glyph)));
}

/** Waits out the rest of the scene after `animation` seconds of motion, so it lasts as long as the voice. */
export function* holdFor(animation: number) {
  yield* waitFor(Math.max(0.2, length - animation));
}
