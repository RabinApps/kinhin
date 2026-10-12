// Resolves a project's look: the named theme with the project's overrides on top, and the output format.
// Plain JavaScript with no Node APIs, so the Node scripts and the Motion Canvas scenes (in the browser) share it.

export const FORMATS = {
  '16:9': {width: 1920, height: 1080, label: 'YouTube, the web, a site hero'},
  '9:16': {width: 1080, height: 1920, label: 'Shorts, Reels, TikTok'},
  '4:5': {width: 1080, height: 1350, label: 'Instagram and LinkedIn feeds'},
  '1:1': {width: 1080, height: 1080, label: 'Square'},
};

// The scene types and how long each one's animation lasts at least (seconds) when a scene gives no `minLength`.
// `designWidth` is how wide a canvas scene's content is in narrow (portrait and square) frames, in design pixels: the
// scene is scaled so that width fills the frame.
export const SCENE_TYPES = {
  title: {kind: 'canvas', minLength: 4.2, designWidth: 1100},
  statement: {kind: 'canvas', minLength: 3, designWidth: 1500},
  queue: {kind: 'canvas', minLength: 7.9, designWidth: 1100},
  parallel: {kind: 'canvas', minLength: 4.6, designWidth: 1350},
  map: {kind: 'canvas', minLength: 6, designWidth: 1700},
  outro: {kind: 'canvas', minLength: 5.8, designWidth: 1300},
  stats: {kind: 'canvas', minLength: 4.5, designWidth: 1100},
  steps: {kind: 'canvas', minLength: 5, designWidth: 1560},
  code: {kind: 'canvas', minLength: 6, designWidth: 1640},
  compare: {kind: 'canvas', minLength: 6, designWidth: 1560},
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
 * (portrait and square) fit `designWidth` (default 1700: the widest content) by width, so the content fills the frame
 * instead of floating in it. The frame scripts (laptop, terminal window) use the default.
 */
export const fitScale = (format, designWidth = 1700) =>
  !isNarrow(format) ? Math.min(format.width / 1920, format.height / 1080) : format.width / designWidth;

// ---- Captions ---------------------------------------------------------------------------------------------------------

/** The caption looks a project can pick with `captions.style` (or `--caption-style`). */
export const CAPTION_STYLES = {
  outline: {border: 'outline', description: 'text with a contrasting outline (the default)'},
  box: {border: 'box', description: 'text on a semi-transparent box'},
  shadow: {border: 'shadow', description: 'text with a soft drop shadow, no outline'},
  bold: {border: 'outline', bold: true, size: 1.25, description: 'larger, bold text with an outline'},
  minimal: {border: 'none', size: 0.85, description: 'small, plain text'},
};
export const CAPTION_POSITIONS = ['auto', 'bottom', 'top', 'middle'];
const HEX = /^#[0-9a-f]{6}([0-9a-f]{2})?$/i;

/** What is wrong with a project's "captions" block, in words. */
export function validateCaptions(cfg) {
  const problems = [];
  if (cfg === undefined) return problems;
  if (typeof cfg !== 'object' || cfg === null || Array.isArray(cfg)) return ['"captions" must be an object'];
  if ('burn' in cfg && typeof cfg.burn !== 'boolean') problems.push('captions.burn must be true or false');
  if ('sidecar' in cfg && typeof cfg.sidecar !== 'boolean') problems.push('captions.sidecar must be true or false');
  if ('style' in cfg && !(cfg.style in CAPTION_STYLES)) problems.push(`captions.style "${cfg.style}" is not one of ${Object.keys(CAPTION_STYLES).join(', ')}`);
  if ('position' in cfg && !CAPTION_POSITIONS.includes(cfg.position)) problems.push(`captions.position "${cfg.position}" is not one of ${CAPTION_POSITIONS.join(', ')}`);
  if ('scenes' in cfg && !(cfg.scenes === 'clips' || cfg.scenes === 'all' || (Array.isArray(cfg.scenes) && cfg.scenes.every((x) => typeof x === 'string')))) problems.push('captions.scenes must be "clips", "all" or a list of scene ids');
  if ('size' in cfg && !(typeof cfg.size === 'number' && cfg.size > 0 && cfg.size <= 3)) problems.push('captions.size must be a number above 0 and up to 3 (a multiplier)');
  for (const k of ['color', 'outlineColor', 'boxColor']) if (k in cfg && !HEX.test(cfg[k])) problems.push(`captions.${k} must be a hex colour like #ffffff (or #000000b3 with opacity)`);
  return problems;
}

/** `#rrggbb` or `#rrggbbaa` as libass's `&HAABBGGRR&` (its alpha is inverted: 00 is opaque). */
export function assColor(hex) {
  const h = hex.replace('#', '');
  const alpha = h.length === 8 ? 255 - parseInt(h.slice(6, 8), 16) : 0;
  const hh = (n) => n.toString(16).padStart(2, '0').toUpperCase();
  return `&H${hh(alpha)}${h.slice(4, 6)}${h.slice(2, 4)}${h.slice(0, 2)}&`.toUpperCase();
}

/**
 * The caption settings a build uses. Later wins: the theme's caption look, the adapter's "captions", the project's
 * "captions", then the environment (VIDEO_CAPTIONS=on|off|all, VIDEO_CAPTION_STYLE, CAPTION_SCENES, and the older
 * NO_CAPTIONS). `burn: false` leaves the picture clean; the caption file for a player (out/<name>.srt) is written either way.
 */
export function resolveCaptions({theme, project = {}, adapter = {}, env = {}}) {
  const cfg = deepMerge(deepMerge({}, adapter.captions ?? {}), project.captions ?? {});
  const problems = [...validateCaptions(adapter.captions), ...validateCaptions(project.captions)];
  if (problems.length) throw new Error(problems.join('; '));
  let burn = cfg.burn ?? true;
  let scenes = cfg.scenes ?? 'clips';
  const mode = (env.VIDEO_CAPTIONS || '').toLowerCase();
  if (mode && !['on', 'off', 'all'].includes(mode)) throw new Error(`VIDEO_CAPTIONS must be on, off or all, not "${env.VIDEO_CAPTIONS}"`);
  if (env.NO_CAPTIONS || mode === 'off') burn = false;
  if (mode === 'on') burn = true;
  if (mode === 'all') {
    burn = true;
    scenes = 'all';
  }
  if (env.CAPTION_SCENES) scenes = env.CAPTION_SCENES.split(',');
  const style = env.VIDEO_CAPTION_STYLE || cfg.style || (theme.caption.box ? 'box' : 'outline');
  if (!(style in CAPTION_STYLES)) throw new Error(`unknown caption style "${style}" (${Object.keys(CAPTION_STYLES).join(', ')})`);
  const preset = CAPTION_STYLES[style];
  return {
    burn,
    scenes,
    style,
    border: preset.border,
    bold: cfg.bold ?? preset.bold ?? false,
    scale: (cfg.size ?? 1) * (preset.size ?? 1),
    position: cfg.position ?? 'auto',
    font: cfg.font ?? theme.font.family,
    text: cfg.color ?? theme.caption.text,
    outline: cfg.outlineColor ?? theme.caption.outline,
    box: cfg.boxColor ?? theme.caption.boxColor ?? '#000000b3',
    sidecar: cfg.sidecar !== false,
  };
}

// ---- Music ------------------------------------------------------------------------------------------------------------

const normalizeMusic = (x) => (x === false ? {enabled: false} : x === true || x === undefined || x === null ? {} : typeof x === 'string' ? {track: x} : x);

/** What is wrong with a "music" setting (false, a track name or path, or an object), in words. */
export function validateMusic(raw) {
  const problems = [];
  if (raw === undefined || typeof raw === 'boolean' || typeof raw === 'string') return problems;
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return ['"music" must be false, a track, or an object'];
  if ('enabled' in raw && typeof raw.enabled !== 'boolean') problems.push('music.enabled must be true or false');
  if ('track' in raw && (typeof raw.track !== 'string' || !raw.track)) problems.push('music.track must be a catalog name, a file path or an https URL');
  if (typeof raw.track === 'string' && /^https?:\/\//.test(raw.track)) {
    if (!raw.track.startsWith('https://')) problems.push('music.track: a URL must be https');
    if (!/^[0-9a-f]{64}$/i.test(raw.sha256 ?? '')) problems.push('music.sha256 (64 hex digits) is required with a URL, so the file is checked');
  }
  if ('sha256' in raw && !/^[0-9a-f]{64}$/i.test(raw.sha256)) problems.push('music.sha256 must be 64 hex digits');
  if ('volume' in raw && !(typeof raw.volume === 'number' && raw.volume >= 0 && raw.volume <= 1.5)) problems.push('music.volume must be a number from 0 to 1.5');
  for (const k of ['fadeIn', 'fadeOut']) if (k in raw && !(typeof raw[k] === 'number' && raw[k] >= 0 && raw[k] <= 30)) problems.push(`music.${k} must be seconds from 0 to 30`);
  if ('start' in raw && !(typeof raw.start === 'number' && raw.start >= 0)) problems.push('music.start must be seconds into the track, 0 or more');
  for (const k of ['duck', 'loop']) if (k in raw && typeof raw[k] !== 'boolean') problems.push(`music.${k} must be true or false`);
  if ('credit' in raw && typeof raw.credit !== 'string') problems.push('music.credit must be text');
  return problems;
}

/**
 * The music a build uses. Later wins: the adapter's "music", the project's, then the environment (VIDEO_MUSIC = a track,
 * a path, or off; VIDEO_MUSIC_VOLUME; and the older NO_MUSIC). A project's `"music": false` turns off what an adapter
 * selects. With no track selected there is no music. `credit` is written next to the video when a track has one.
 */
export function resolveMusic({project = {}, adapter = {}, env = {}}) {
  const problems = [...validateMusic(adapter.music), ...validateMusic(project.music)];
  if (problems.length) throw new Error(problems.join('; '));
  const cfg = deepMerge(deepMerge({}, normalizeMusic(adapter.music)), normalizeMusic(project.music));
  let enabled = cfg.enabled !== false;
  let track = cfg.track;
  let sha256 = cfg.sha256;
  const mode = (env.VIDEO_MUSIC ?? '').trim();
  if (env.NO_MUSIC || ['off', 'none', 'false'].includes(mode.toLowerCase())) enabled = false;
  else if (mode) {
    track = mode;
    enabled = true;
    if (/^https?:\/\//.test(mode)) sha256 = env.VIDEO_MUSIC_SHA256 || undefined;
  }
  if (/^https?:\/\//.test(track ?? '') && !/^[0-9a-f]{64}$/i.test(sha256 ?? '')) throw new Error('a music URL needs its sha256 (music.sha256, or VIDEO_MUSIC_SHA256), so the file is checked');
  let volume = cfg.volume ?? 0.35;
  if (env.VIDEO_MUSIC_VOLUME) {
    volume = Number(env.VIDEO_MUSIC_VOLUME);
    if (!(volume >= 0 && volume <= 1.5)) throw new Error('VIDEO_MUSIC_VOLUME must be a number from 0 to 1.5');
  }
  return {enabled: enabled && !!track, track: track ?? null, sha256: sha256 ?? null, volume, duck: cfg.duck ?? true, fadeIn: cfg.fadeIn ?? 2, fadeOut: cfg.fadeOut ?? 3, start: cfg.start ?? 0, loop: cfg.loop ?? true, credit: cfg.credit ?? null};
}

/** True for portrait and square frames, which get their own layouts. */
export const isNarrow = (format) => format.width / format.height < 1.2;

/** Checks a project file and says what is wrong in words. */
export function validateProject(project) {
  const problems = [];
  if (!Array.isArray(project.scenes) || project.scenes.length === 0) problems.push('a project needs a "scenes" list');
  problems.push(...validateCaptions(project.captions), ...validateMusic(project.music));
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
