// Loads a video project: script/<name>.json (or .kinhin/videos/<name>.yml in your own repository: see VIDEO_SOURCE), its theme (video/themes/*.json plus the project's overrides) and format.
// Library for the other scripts; run it directly to inspect or to export the look to shell scripts:
//   node scripts/project.mjs            summary and validation
//   node scripts/project.mjs --adapter  print the project's adapter name (empty if none)
//   node scripts/project.mjs --env      shell variables for the ffmpeg scripts (eval "$(node scripts/project.mjs --env)")
// Env: VIDEO_PROJECT  project name (default "launch")   VIDEO_THEME / VIDEO_FORMAT / VIDEO_ADAPTER  override the project's choice
//      VIDEO_SOURCE  your repository: projects are read from <it>/.kinhin/videos/<name>.yml|.yaml|.json first, adapters from
//        <it>/.kinhin/videos/adapters/<name>/adapter.yml|.json, and local music files relative to it
//      VIDEO_CAPTIONS (on|off|all) / VIDEO_CAPTION_STYLE  override its captions
import {existsSync, readFileSync, readdirSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {parse as parseYaml} from 'yaml';
import {SCENE_TYPES, fitScale, isNarrow, resolveCaptions, resolveFormat, resolveMusic, resolveTheme, validateProject} from '../shared/resolve.mjs';

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

const CONFIG_EXTS = ['.yml', '.yaml', '.json'];

/** A user's repository (VIDEO_SOURCE) or null; its video configs live in <repo>/.kinhin/videos/. */
export const sourceDir = () => (process.env.VIDEO_SOURCE ? resolve(process.env.VIDEO_SOURCE) : null);
export const videosDir = () => (sourceDir() ? join(sourceDir(), '.kinhin', 'videos') : null);

/** Reads a YAML or JSON config file. */
export function readConfig(file) {
  const text = readFileSync(file, 'utf8');
  try {
    return file.endsWith('.json') ? JSON.parse(text) : (parseYaml(text) ?? {});
  } catch (e) {
    throw new Error(`${file}: ${e.message}`);
  }
}

const firstExisting = (base) => CONFIG_EXTS.map((e) => base + e).find(existsSync);

/** The names of the projects in <repo>/.kinhin/videos/ (subfolders count: "launch/short"; adapters/ does not). */
export function listSourceProjects(dir = videosDir(), prefix = '') {
  if (!dir || !existsSync(dir)) return [];
  return readdirSync(dir, {withFileTypes: true}).flatMap((d) =>
    d.isDirectory() ? (prefix === '' && d.name === 'adapters' ? [] : listSourceProjects(join(dir, d.name), `${prefix}${d.name}/`)) : CONFIG_EXTS.some((e) => d.name.endsWith(e)) ? [prefix + d.name.replace(/\.(ya?ml|json)$/, '')] : [],
  );
}

/** Finds an adapter's manifest: your repository's .kinhin/videos/adapters/<name>/ first, then video/adapters/<name>/. */
export function adapterFile(name) {
  const own = videosDir() && firstExisting(join(videosDir(), 'adapters', name, 'adapter'));
  return own ?? firstExisting(join(root, 'adapters', name, 'adapter'));
}

/** Finds a project file: a path, else <repo>/.kinhin/videos/<name>.yml|.yaml|.json, else video/script/<name>.json. */
export function projectFile(name) {
  if (CONFIG_EXTS.some((e) => name.endsWith(e))) return resolve(name);
  const found = (videosDir() && firstExisting(join(videosDir(), name))) || (existsSync(join(root, 'script', `${name}.json`)) ? join(root, 'script', `${name}.json`) : null);
  if (found) return found;
  const where = videosDir() ? `${videosDir()}/${name}.yml or ` : '';
  const have = listSourceProjects();
  throw new Error(`no video project "${name}" (${where}video/script/${name}.json${have.length ? `; in your repository: ${have.join(', ')}` : ''})`);
}

export function loadThemes() {
  const dir = join(root, 'themes');
  return Object.fromEntries(
    readdirSync(dir).filter((f) => f.endsWith('.json')).map((f) => [f.replace(/\.json$/, ''), JSON.parse(readFileSync(join(dir, f), 'utf8'))]),
  );
}

export function loadProject(name = process.env.VIDEO_PROJECT || 'launch') {
  const file = projectFile(name);
  const project = readConfig(file);
  const problems = validateProject(project);
  if (problems.length) throw new Error(`${file}:\n  - ${problems.join('\n  - ')}`);
  const themeName = process.env.VIDEO_THEME || project.theme || 'paper';
  const formatName = process.env.VIDEO_FORMAT || project.format || '16:9';
  const theme = resolveTheme(loadThemes(), themeName, project.overrides);
  const format = resolveFormat(formatName);
  const scenes = project.scenes.map((s) => ({...s, ...SCENE_TYPES[s.type], props: s.props ?? {}, minLength: s.minLength ?? SCENE_TYPES[s.type].minLength}));
  // The project's name relative to video/script/ ("launch", "examples/scene-types"); `slug` is safe in file names.
  const base = [join(root, 'script'), videosDir()].find((d) => d && file.startsWith(d + '/'));
  const stem = (base ? file.slice(base.length + 1) : file.replace(/^.*\//, '')).replace(/\.(json|ya?ml)$/, '');
  const slug = stem.replace(/\//g, '-');
  // out/<stem>.mp4 for the project's own look; a theme or format chosen on the command line is added to the name.
  const outName = [slug, process.env.VIDEO_THEME, process.env.VIDEO_FORMAT?.replace(':', 'x')].filter(Boolean).join('-');
  const adapter = process.env.VIDEO_ADAPTER || project.adapter || null;
  const manifestFile = adapter && adapterFile(adapter);
  const adapterManifest = manifestFile ? readConfig(manifestFile) : {};
  const captions = resolveCaptions({theme, project, adapter: adapterManifest, env: process.env});
  const music = resolveMusic({project, adapter: adapterManifest, env: process.env});
  return {name: project.name ?? stem, stem, slug, outName, adapter, captions, music, file, project, scenes, theme, format, fit: fitScale(format)};
}

const hex = (c) => c.replace('#', '0x');
// ASS colours are &HBBGGRR&.
const ass = (c) => `&H${c.slice(5, 7)}${c.slice(3, 5)}${c.slice(1, 3)}&`.toUpperCase();

/** The look as shell variable assignments for the ffmpeg scripts. */
export function shellEnv({theme, format, fit}) {
  const d = theme.device;
  const vars = {
    VIDEO_W: format.width, VIDEO_H: format.height, VIDEO_FIT: fit.toFixed(4), VIDEO_NARROW: isNarrow(format) ? 1 : 0, TERMINAL_MODE: d.terminal ?? 'light',
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
    else if (process.argv.includes('--adapter')) console.log(p.adapter ?? '');
    else {
      console.log(`${p.name}: theme ${p.theme.name} (${p.theme.font.family}), ${p.format.name} ${p.format.width}x${p.format.height}`);
      console.log(p.scenes.map((s) => `  ${s.id.padEnd(10)} ${s.type}`).join('\n'));
    }
  } catch (e) {
    console.error(String(e.message));
    process.exit(1);
  }
}
