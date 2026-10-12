// Loads a video project: script/<name>.json, its theme (video/themes/*.json plus the project's overrides) and format.
// Library for the other scripts; run it directly to inspect or to export the look to shell scripts:
//   node scripts/project.mjs            summary and validation
//   node scripts/project.mjs --env      shell variables for the ffmpeg scripts (eval "$(node scripts/project.mjs --env)")
// Env: VIDEO_PROJECT  project name (default "launch")   VIDEO_THEME / VIDEO_FORMAT  override the project's choice
import {readFileSync, readdirSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {SCENE_TYPES, fitScale, resolveFormat, resolveTheme, validateProject} from '../shared/resolve.mjs';

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export function loadThemes() {
  const dir = join(root, 'themes');
  return Object.fromEntries(
    readdirSync(dir).filter((f) => f.endsWith('.json')).map((f) => [f.replace(/\.json$/, ''), JSON.parse(readFileSync(join(dir, f), 'utf8'))]),
  );
}

export function loadProject(name = process.env.VIDEO_PROJECT || 'launch') {
  const file = name.endsWith('.json') ? resolve(name) : join(root, 'script', `${name}.json`);
  const project = JSON.parse(readFileSync(file, 'utf8'));
  const problems = validateProject(project);
  if (problems.length) throw new Error(`${file}:\n  - ${problems.join('\n  - ')}`);
  const themeName = process.env.VIDEO_THEME || project.theme || 'paper';
  const formatName = process.env.VIDEO_FORMAT || project.format || '16:9';
  const theme = resolveTheme(loadThemes(), themeName, project.overrides);
  const format = resolveFormat(formatName);
  const scenes = project.scenes.map((s) => ({...s, ...SCENE_TYPES[s.type], props: s.props ?? {}, minLength: s.minLength ?? SCENE_TYPES[s.type].minLength}));
  const stem = file.replace(/^.*\//, '').replace(/\.json$/, '');
  // out/<stem>.mp4 for the project's own look; a theme or format chosen on the command line is added to the name.
  const outName = [stem, process.env.VIDEO_THEME, process.env.VIDEO_FORMAT?.replace(':', 'x')].filter(Boolean).join('-');
  return {name: project.name ?? stem, stem, outName, file, project, scenes, theme, format, fit: fitScale(format)};
}

const hex = (c) => c.replace('#', '0x');
// ASS colours are &HBBGGRR&.
const ass = (c) => `&H${c.slice(5, 7)}${c.slice(3, 5)}${c.slice(1, 3)}&`.toUpperCase();

/** The look as shell variable assignments for the ffmpeg scripts. */
export function shellEnv({theme, format, fit}) {
  const d = theme.device;
  const vars = {
    VIDEO_W: format.width, VIDEO_H: format.height, VIDEO_FIT: fit.toFixed(4),
    BG_FROM: hex(theme.background.from), BG_TO: hex(theme.background.to),
    WALL_FROM: hex(d.wallpaper.from), WALL_TO: hex(d.wallpaper.to),
    LID_COLOR: hex(d.lid), BASE_FROM: hex(d.baseFrom), BASE_TO: hex(d.baseTo), THUMB_COLOR: hex(d.thumb),
    BAR_COLOR: hex(d.windowBar), BODY_COLOR: hex(d.windowBody), SHADOW_ALPHA: d.shadow,
    CAPTION_FONT: theme.font.family, CAPTION_SIZE: theme.caption.size,
    CAPTION_TEXT: ass(theme.caption.text), CAPTION_OUTLINE: ass(theme.caption.outline),
  };
  return Object.entries(vars).map(([k, v]) => `export ${k}='${v}'`).join('\n');
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const p = loadProject();
    if (process.argv.includes('--env')) console.log(shellEnv(p));
    else {
      console.log(`${p.name}: theme ${p.theme.name} (${p.theme.font.family}), ${p.format.name} ${p.format.width}x${p.format.height}`);
      console.log(p.scenes.map((s) => `  ${s.id.padEnd(10)} ${s.type}`).join('\n'));
    }
  } catch (e) {
    console.error(String(e.message));
    process.exit(1);
  }
}
