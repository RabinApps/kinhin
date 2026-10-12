import {Gradient, Node, type View2D} from '@motion-canvas/2d';
import {waitFor} from '@motion-canvas/core';
import {fit, length, theme} from './config';

export const C = theme.colors;
export const FONT = theme.font.css;
export const WEIGHT = theme.font.weight ?? 600;

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

/** Waits out the rest of the scene after `animation` seconds of motion, so it lasts as long as the voice. */
export function* holdFor(animation: number) {
  yield* waitFor(Math.max(0.2, length - animation));
}
