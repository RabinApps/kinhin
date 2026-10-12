// Resolves a project's look: the named theme with the project's overrides on top, and the output format.
// Plain JavaScript with no Node APIs, so the Node scripts and the Motion Canvas scenes (in the browser) share it.

export const FORMATS = {
  '16:9': {width: 1920, height: 1080, label: 'YouTube, the web, a site hero'},
  '9:16': {width: 1080, height: 1920, label: 'Shorts, Reels, TikTok'},
  '4:5': {width: 1080, height: 1350, label: 'Instagram and LinkedIn feeds'},
  '1:1': {width: 1080, height: 1080, label: 'Square'},
};

// The scene types and how long each one's animation lasts at least (seconds) when a scene gives no `minLength`.
export const SCENE_TYPES = {
  title: {kind: 'canvas', minLength: 4.2},
  statement: {kind: 'canvas', minLength: 3},
  queue: {kind: 'canvas', minLength: 7.9},
  parallel: {kind: 'canvas', minLength: 4.6},
  map: {kind: 'canvas', minLength: 6},
  outro: {kind: 'canvas', minLength: 5.8},
  device: {kind: 'clip', minLength: 0},
  terminal: {kind: 'clip', minLength: 0},
};

export function deepMerge(base, extra) {
  if (extra === undefined || extra === null) return base;
  if (typeof base !== 'object' || base === null || Array.isArray(base)) return extra;
  const out = {...base};
  for (const [key, value] of Object.entries(extra)) {
    out[key] = key in base && typeof value === 'object' && value !== null && !Array.isArray(value) ? deepMerge(base[key], value) : value;
  }
  return out;
}

/** The theme named `name` (from `themes`, an object of name -> theme) with `overrides` merged on top. */
export function resolveTheme(themes, name, overrides = {}) {
  const theme = themes[name ?? 'paper'];
  if (!theme) {
    throw new Error(`unknown theme "${name}" (available: ${Object.keys(themes).sort().join(', ')}; add one as video/themes/${name}.json)`);
  }
  const merged = deepMerge(theme, overrides);
  const family = merged.font.family;
  return {...merged, font: {...merged.font, css: `${quote(family)}, ${merged.font.fallback}`}};
}

const quote = (family) => (/^[\w-]+$/.test(family) ? family : `"${family}"`);

export function resolveFormat(name = '16:9') {
  const format = FORMATS[name];
  if (!format) throw new Error(`unknown format "${name}" (available: ${Object.keys(FORMATS).join(', ')})`);
  return {name, ...format};
}

/**
 * Scale from the 1920x1080 design space to a format's frame. Landscape frames fit the whole design; narrow frames
 * (portrait and square) fit its central 1700 px by width, so the content fills the frame instead of floating in it.
 */
export const fitScale = (format) =>
  format.width / format.height >= 1.2 ? Math.min(format.width / 1920, format.height / 1080) : format.width / 1700;

/** Checks a project file and says what is wrong in words. */
export function validateProject(project) {
  const problems = [];
  if (!Array.isArray(project.scenes) || project.scenes.length === 0) problems.push('a project needs a "scenes" list');
  const ids = new Set();
  for (const [i, scene] of (project.scenes ?? []).entries()) {
    const where = `scene ${i + 1}${scene.id ? ` ("${scene.id}")` : ''}`;
    if (!scene.id) problems.push(`${where} has no "id"`);
    else if (ids.has(scene.id)) problems.push(`${where}: the id is used twice`);
    ids.add(scene.id);
    if (!(scene.type in SCENE_TYPES)) problems.push(`${where}: unknown type "${scene.type}" (${Object.keys(SCENE_TYPES).join(', ')})`);
    if (!scene.narration && !scene.cues) problems.push(`${where} has neither "narration" nor "cues"`);
  }
  return problems;
}
