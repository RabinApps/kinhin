import {Gradient} from '@motion-canvas/2d';
// Brand: the black ring on white, nothing else (assets/brand/README.md).
export const INK = '#000000';
export const PAPER = '#ffffff';
export const MUTED = '#6b6b6b';
export const FONT = 'Inter, -apple-system, "SF Pro Display", "Helvetica Neue", Helvetica, Arial, sans-serif';
export const MONO = '"SF Mono", Menlo, Consolas, monospace';

// The soft white-to-blue backdrop shared by every scene and the app shot (scripts/frame-app.sh paints the same one).
export const BACKGROUND = new Gradient({
  type: 'linear',
  from: [0, -540],
  to: [0, 540],
  stops: [
    {offset: 0, color: '#ffffff'},
    {offset: 1, color: '#e6ebf5'},
  ],
});
