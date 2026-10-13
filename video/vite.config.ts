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
});
