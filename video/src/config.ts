import {SCENE_TYPES, fitScale, isNarrow, resolveFormat, resolveTheme, validateProject, type Theme} from '../shared/resolve.mjs';
import {timing} from './timing';

// Everything a scene needs, resolved from the project file, the theme and the environment. The render script
// (scripts/render-titles.mjs) starts the editor once per scene with VITE_VIDEO_PROJECT, VITE_VIDEO_THEME,
// VITE_VIDEO_FORMAT and VITE_SCENE_ID set.
const themeFiles = import.meta.glob('../themes/*.json', {eager: true, import: 'default'}) as Record<string, any>;
const projectFiles = import.meta.glob('../script/*.json', {eager: true, import: 'default'}) as Record<string, any>;
const env = import.meta.env;

const themes = Object.fromEntries(Object.entries(themeFiles).map(([path, t]) => [path.replace(/^.*\/(.*)\.json$/, '$1'), t]));
const projectName = env.VITE_VIDEO_PROJECT || 'launch';
const project = projectFiles[`../script/${projectName}.json`];
if (!project) throw new Error(`no project "${projectName}" in video/script/`);
const problems = validateProject(project);
if (problems.length) throw new Error(`${projectName}.json: ${problems.join('; ')}`);

const sceneId: string = env.VITE_SCENE_ID || project.scenes.find((s: any) => SCENE_TYPES[s.type as keyof typeof SCENE_TYPES].kind === 'canvas').id;
const scene = project.scenes.find((s: any) => s.id === sceneId);
if (!scene) throw new Error(`the project has no scene "${sceneId}"`);

export const theme: Theme = resolveTheme(themes, env.VITE_VIDEO_THEME || project.theme, project.overrides);
export const format = resolveFormat(env.VITE_VIDEO_FORMAT || project.format);
export const fit = fitScale(format);
/** Portrait and square frames: scenes lay out vertically (see queue.tsx and map.tsx). */
export const narrow = isNarrow(format);
export const sceneType: string = scene.type;
export const props: any = scene.props ?? {};
/** How long this scene lasts, in seconds: the voice-over's length (src/timing.ts), never less than the animation. */
export const length: number = (timing as Record<string, number>)[sceneId] ?? scene.minLength ?? SCENE_TYPES[scene.type as keyof typeof SCENE_TYPES].minLength;
