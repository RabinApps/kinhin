import {defineConfig} from 'vite';
import motionCanvasModule from '@motion-canvas/vite-plugin';
import ffmpegModule from '@motion-canvas/ffmpeg';

// The plugins ship CommonJS; under "type": "module" the default import is the module object.
const motionCanvas = (motionCanvasModule as any).default ?? motionCanvasModule;
const ffmpeg = (ffmpegModule as any).default ?? ffmpegModule;

// One Motion Canvas project renders one scene: VITE_SCENE_ID picks it from the project file (src/config.ts) and
// scripts/render-titles.mjs loops over the scenes. By hand: VITE_SCENE_ID=intro npm run serve
const project = 'titles';

export default defineConfig({
  plugins: [motionCanvas({project: `./src/${project}.ts`}), ffmpeg()],
  // Vite 6 finds these late on a cold start and re-bundles them, leaving the editor with two copies of
  // @motion-canvas/core ("useApplication() is null", no Render button). Listing them bundles them in one pass.
  optimizeDeps: {
    include: [
      '@motion-canvas/core',
      '@motion-canvas/2d',
      '@motion-canvas/2d/lib/jsx-dev-runtime',
      '@motion-canvas/ffmpeg/lib/client',
      '@motion-canvas/ui',
    ],
  },
});
