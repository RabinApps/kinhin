import {defineConfig} from 'vite';
import motionCanvasModule from '@motion-canvas/vite-plugin';
import ffmpegModule from '@motion-canvas/ffmpeg';

// The plugins ship CommonJS; under "type": "module" the default import is the module object.
const motionCanvas = (motionCanvasModule as any).default ?? motionCanvasModule;
const ffmpeg = (ffmpegModule as any).default ?? ffmpegModule;

// Two projects render to two clips; scripts/export.sh joins them around the
// screen recordings. Pick one: VIDEO_PROJECT=opening|closing npm run serve
const project = process.env.VIDEO_PROJECT ?? 'opening';

export default defineConfig({
  plugins: [motionCanvas({project: `./src/${project}.ts`}), ffmpeg()],
});
