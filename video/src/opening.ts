import {makeProject} from '@motion-canvas/core';
import intro from './scenes/intro?scene';
import problem from './scenes/problem?scene';
import solution from './scenes/solution?scene';

export default makeProject({scenes: [intro, problem, solution]});
