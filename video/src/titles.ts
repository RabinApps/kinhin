import {makeProject} from '@motion-canvas/core';
import code from './scenes/code?scene';
import compare from './scenes/compare?scene';
import map from './scenes/map?scene';
import outro from './scenes/outro?scene';
import parallel from './scenes/parallel?scene';
import queue from './scenes/queue?scene';
import stats from './scenes/stats?scene';
import steps from './scenes/steps?scene';
import statement from './scenes/statement?scene';
import title from './scenes/title?scene';
import {sceneType} from './config';

// One scene per render: scripts/render-titles.mjs starts the editor with VITE_SCENE_ID set, and the scene's
// `type` in the project file picks the scene below. Add a type by adding a file in scenes/ and a line here.
const byType = {title, statement, queue, parallel, map, outro, stats, steps, code, compare};
const scene = byType[sceneType as keyof typeof byType];
if (!scene) throw new Error(`"${sceneType}" is not a canvas scene type`);

export default makeProject({scenes: [scene]});
