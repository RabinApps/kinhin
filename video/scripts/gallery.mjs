#!/usr/bin/env node
// Builds a gallery of everything the suite can do: every example project at its own look, the hello example in every theme,
// and in every format. For each build it keeps the video, a poster and a strip of frames (one per scene), then writes
// out/gallery/index.html (videos you can play) and, with --write-docs, the committed docs/video-gallery.md with the strips
// in docs/assets/video-gallery/.
//
// Usage: node scripts/gallery.mjs [--only a,b] [--full] [--host] [--runtime container|docker] [--write-docs] [--no-build]
//   --only      comma-separated case names (see --list)
//   --full      full quality (the default is --fast, which is what the strips and posters need)
//   --no-build  only regenerate the page and docs from what is already in out/gallery/
//   --list      print the cases
// Every build is the real thing: scripts/build.sh, in a container unless --host.
import {execFileSync, spawnSync} from 'node:child_process';
import {copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {loadProject, root} from './project.mjs';
import {CAPTION_STYLES, FORMATS} from '../shared/resolve.mjs';

process.chdir(root);
const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const opt = (n) => (args.includes(n) ? args[args.indexOf(n) + 1] : undefined);
const repo = join(root, '..');
const galleryDir = join(root, 'out/gallery');
const docsAssets = join(repo, 'docs/assets/video-gallery');

const themes = readdirSync('themes').filter((f) => f.endsWith('.json')).map((f) => f.replace('.json', ''));
const examples = readdirSync('script/examples').filter((f) => f.endsWith('.json') && !f.startsWith('tmp-')).map((f) => f.replace('.json', ''));
const blurb = {
  hello: 'The smallest video: a title, one sentence, a closing line.',
  'scene-tour': 'All ten canvas scene types, one after another.',
  'product-launch': 'A product launch: problem, before and after, numbers, steps.',
  'release-notes': 'Release notes: a statement per feature, then the numbers.',
  'social-teaser': 'A fifteen-second vertical teaser for Shorts, Reels and TikTok.',
  'tutorial-chalk': 'A tutorial on a chalkboard: a plan and the commands.',
  'architecture-blueprint': 'An architecture explainer in blueprint style.',
  'oss-announcement': 'An open-source announcement for a 4:5 feed.',
  'changelog-month': 'A monthly update, square, with numbers and highlights.',
  'code-walkthrough': 'Code that types itself: install, then verify.',
  'kinhin-30s': 'kinhin in thirty seconds, with the kinhin adapter\'s recorded app clip in a laptop.',
};
const cases = [
  ...examples.map((e) => ({name: e, project: `examples/${e}`, title: e, text: blurb[e] ?? '', group: 'examples'})),
  {name: 'template-demo', project: 'template-demo', title: 'template-demo', text: 'The template adapter: an app clip in a laptop, a browser session and a terminal, each in its frame.', group: 'examples'},
  {name: 'launch', project: 'launch', title: 'launch', text: 'The kinhin launch video: seven scenes, a recorded app, voice-over and music.', group: 'examples'},
  ...themes.map((t) => ({name: `hello-${t}`, project: 'examples/hello', theme: t, title: t, text: `The hello example in the ${t} theme.`, group: 'themes'})),
  ...[['off', 'Captions off', 'No burned-in captions; the .srt is still written.'], ...Object.keys(CAPTION_STYLES).map((st) => [st, `Captions: ${st}`, CAPTION_STYLES[st].description[0].toUpperCase() + CAPTION_STYLES[st].description.slice(1) + '.'])].map(([k, title, text]) => ({
    name: `captions-${k}`, project: 'template-demo', title, text, group: 'captions', flags: k === 'off' ? ['--captions', 'off'] : ['--caption-style', k],
  })),
  ...Object.keys(FORMATS).map((f) => ({name: `hello-${f.replace(':', 'x')}`, project: 'examples/hello', format: f, title: f, text: `The hello example at ${f} (${FORMATS[f].label}).`, group: 'formats'})),
];
if (flag('--list')) { console.log(cases.map((c) => c.name).join('\n')); process.exit(0); }
const only = opt('--only')?.split(',');
const todo = only ? cases.filter((c) => only.includes(c.name)) : cases;

const ffmpeg = (a) => execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', ...a]);
mkdirSync(galleryDir, {recursive: true});
const indexFile = join(galleryDir, 'index.json');
const index = existsSync(indexFile) ? JSON.parse(readFileSync(indexFile, 'utf8')) : {};

function strip(video, timeline, out, group) {
  const entries = Object.entries(timeline.scenes);
  if (group === 'captions') {
    // One frame, while the first cue of the first clip scene is on screen: that is where the style shows.
    const [, s] = entries.find(([, x]) => x.kind === 'clip');
    ffmpeg(['-ss', String(s.start + 1.8), '-i', video, '-frames:v', '1', '-vf', 'scale=-2:420', '-q:v', '4', out]);
    return;
  }
  const picks = entries.length <= 5 ? entries : [0, 1, 2, 3, 4].map((i) => entries[Math.round((i * (entries.length - 1)) / 4)]);
  const narrow = timeline.format.width / timeline.format.height < 1.2;
  const h = narrow ? 360 : 240;
  const frames = picks.map(([id, s], i) => {
    const f = join(galleryDir, `.f${i}.jpg`);
    ffmpeg(['-ss', String(s.start + Math.min(s.length * 0.8, s.length - 0.6)), '-i', video, '-frames:v', '1', '-vf', `scale=-2:${h}`, '-q:v', '4', f]);
    return f;
  });
  ffmpeg([...frames.flatMap((f) => ['-i', f]), '-filter_complex', `hstack=inputs=${frames.length}`, '-q:v', '5', out]);
}

if (!flag('--no-build')) {
  for (const c of todo) {
    console.log(`\n=== ${c.name} (${c.project}${c.theme ? `, ${c.theme}` : ''}${c.format ? `, ${c.format}` : ''})`);
    const buildArgs = [...(flag('--host') ? [] : ['--container', ...(opt('--runtime') ? ['--runtime', opt('--runtime')] : [])]), '--project', c.project];
    if (c.theme) buildArgs.push('--theme', c.theme);
    if (c.format) buildArgs.push('--format', c.format);
    if (c.flags) buildArgs.push(...c.flags);
    if (!flag('--full')) buildArgs.push('--fast');
    const r = spawnSync('scripts/build.sh', buildArgs, {stdio: ['ignore', 'pipe', 'inherit'], encoding: 'utf8', maxBuffer: 256 << 20});
    process.stdout.write(r.stdout.split('\n').filter((l) => /^==>|wrote out|rendered|cached/.test(l)).join('\n') + '\n');
    const built = r.stdout.match(/wrote out\/[\w.-]+\/([\w.-]+)\.mp4 \(/)?.[1];
    if (r.status !== 0 || !built) { console.error(`FAILED: ${c.name}`); index[c.name] = {...c, failed: true}; continue; }
    const timeline = JSON.parse(readFileSync('out/.work/timeline.json', 'utf8'));
    copyFileSync('out/.work/timeline.json', join(galleryDir, `${c.name}.timeline.json`)); // so strips can be remade without rebuilding
    copyFileSync(`out/${built}/${built}.mp4`, join(galleryDir, `${c.name}.mp4`));
    ffmpeg(['-i', `out/${built}/${built}-poster.png`, '-vf', 'scale=640:-2', '-q:v', '4', join(galleryDir, `${c.name}.jpg`)]);
    strip(`out/${built}/${built}.mp4`, timeline, join(galleryDir, `${c.name}-strip.jpg`), c.group);
    const p = loadProject(c.project);
    index[c.name] = {...c, failed: false, seconds: Math.round(timeline.total), format: c.format ?? p.format.name, theme: c.theme ?? p.theme.name, types: [...new Set(Object.values(timeline.scenes).map((s) => s.type))], scenes: Object.keys(timeline.scenes).length, bytes: execFileSync('stat', ['-f', '%z', `out/${built}/${built}.mp4`]).toString().trim() * 1};
    writeFileSync(indexFile, JSON.stringify(index, null, 2));
  }
}

// The page: play every video.
// A sensible order: the smallest first, the tour, then the rest by how much they show off.
const order = ['hello', 'scene-tour', 'product-launch', 'release-notes', 'social-teaser', 'tutorial-chalk', 'architecture-blueprint', 'oss-announcement', 'changelog-month', 'code-walkthrough', 'kinhin-30s', 'template-demo', 'launch'];
const rank = (c) => (c.group === 'examples' ? order.indexOf(c.name) : 0);
const done = Object.values(index).filter((c) => !c.failed).sort((a, b) => rank(a) - rank(b));
const card = (c) => `<figure><video controls preload="none" poster="${c.name}.jpg" src="${c.name}.mp4"></video><figcaption><b>${c.title}</b> · ${c.format} · ${c.theme} · ${c.seconds}s<br><small>${c.text}</small></figcaption></figure>`;
const section = (g, h) => (done.some((c) => c.group === g) ? `<h2>${h}</h2><div class="grid">${done.filter((c) => c.group === g).map(card).join('')}</div>` : '');
writeFileSync(join(galleryDir, 'index.html'), `<!doctype html><meta charset="utf-8"><title>Video gallery</title><style>body{font:16px/1.5 system-ui;margin:32px auto;max-width:1400px;padding:0 24px;background:#fafafa;color:#111}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(420px,1fr));gap:24px}video{width:100%;border-radius:12px;background:#000}figcaption{margin-top:8px}small{color:#666}</style><h1>Video gallery</h1>${section('examples', 'Examples')}${section('themes', 'Themes')}${section('captions', 'Captions')}${section('formats', 'Formats')}`);
console.log(`\nwrote ${join(galleryDir, 'index.html')} (${done.length} videos)`);

if (flag('--write-docs')) {
  mkdirSync(docsAssets, {recursive: true});
  for (const c of done) copyFileSync(join(galleryDir, `${c.name}-strip.jpg`), join(docsAssets, `${c.name}.jpg`));
  const entry = (c, cmd) => `### ${c.title}\n\n${c.text}\n\n![${c.title}: a frame from each scene](assets/video-gallery/${c.name}.jpg)\n\n${c.format} · ${c.theme} theme · ${c.seconds} s · ${c.scenes} scenes (${c.types.join(', ')})\n\n\`\`\`bash\n${cmd}\n\`\`\`\n`;
  const cmdOf = (c) => `video/scripts/build.sh --container --project ${c.project}${c.theme ? ` --theme ${c.theme}` : ''}${c.format ? ` --format ${c.format}` : ''}${c.flags ? ` ${c.flags.join(' ')}` : ''}`;
  const md = `# Video gallery

Every video below is built from a JSON file in \`video/script/\` with one command, in a container, from committed sources. Each picture is a
frame from each scene of the real build. To make one of your own, copy a file into your repository's \`.kinhin/videos/\` and run
\`kinhin video build <name>\` (see [Add videos to your project](videos-for-your-project.md)). \`video/scripts/gallery.mjs\` rebuilds all of this
page and writes a page where you can play the videos.

[← Back to README](../README.md) · [Add videos to your project](videos-for-your-project.md) · [Marketing video in CI](ci-video.md)

## Examples

${done.filter((c) => c.group === 'examples').map((c) => entry(c, cmdOf(c))).join('\n')}
## Themes

One project, five looks: change a flag, not the script. A theme sets the font, the colours, the backdrop, the laptop and
window, and the captions. Make your own by copying a file in \`video/themes/\`.

${done.filter((c) => c.group === 'themes').map((c) => entry(c, cmdOf(c))).join('\n')}
## Captions

The same scene with captions off and in each style. Burned-in captions are a project setting (\`captions\` in the JSON) or a flag
(\`--captions off\`, \`--caption-style box\`); the caption file is written either way. See
[Captions](videos-for-your-project.md#captions).

${done.filter((c) => c.group === 'captions').map((c) => entry(c, cmdOf(c))).join('\n')}
## Formats

One project, four frames. Portrait and square frames get their own layouts.

${done.filter((c) => c.group === 'formats').map((c) => entry(c, cmdOf(c))).join('\n')}`;
  writeFileSync(join(repo, 'docs/video-gallery.md'), md);
  console.log('wrote docs/video-gallery.md and docs/assets/video-gallery/');
}
