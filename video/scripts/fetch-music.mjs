// Finds the project's music track and writes out/music.json for assemble.mjs. The track comes from the resolved "music"
// setting (project, adapter, VIDEO_MUSIC): a catalog name (music/catalog.json), a file under video/ (music/my-track.mp3),
// or an https URL with its sha256. Downloads are checked against their SHA-256 and cached in raw/music/; the container image
// carries the catalog's bundled tracks in /opt/music, so a build there needs no network.
// Usage: node scripts/fetch-music.mjs            node scripts/fetch-music.mjs --bake DIR   (download every bundled track into DIR)
import {createHash} from 'node:crypto';
import {copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync} from 'node:fs';
import {dirname, extname, isAbsolute, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const catalog = JSON.parse(readFileSync(join(root, 'music/catalog.json'), 'utf8')).tracks;
const sha = (f) => createHash('sha256').update(readFileSync(f)).digest('hex');
const extOf = (url, fallback = 'wav') => (extname(new URL(url).pathname).slice(1) || fallback).toLowerCase();

async function download(url, want, dest) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  mkdirSync(dirname(dest), {recursive: true});
  writeFileSync(`${dest}.part`, Buffer.from(await res.arrayBuffer()));
  const got = sha(`${dest}.part`);
  if (got !== want.toLowerCase()) throw new Error(`music checksum mismatch for ${url} (got ${got}): the file changed; not using it`);
  renameSync(`${dest}.part`, dest);
}

if (process.argv[2] === '--bake') {
  const dir = process.argv[3] ?? '/opt/music';
  for (const [name, t] of Object.entries(catalog)) if (t.bundled) { await download(t.url, t.sha256, join(dir, `${name}.${t.ext ?? extOf(t.url)}`)); console.log(`baked ${name}`); }
  process.exit(0);
}

const {loadProject} = await import('./project.mjs');
const music = loadProject().music;
mkdirSync(join(root, 'out'), {recursive: true});
const result = (extra) => writeFileSync(join(root, 'out/music.json'), JSON.stringify({...music, file: null, ...extra}, null, 2) + '\n');
if (!music.enabled) { result({enabled: false}); console.log('no music'); process.exit(0); }

let file; let credit = music.credit; let label = music.track;
if (/^https?:\/\//.test(music.track)) {
  file = join(root, 'raw/music', `${music.sha256.slice(0, 16)}.${extOf(music.track)}`);
  if (!existsSync(file) || sha(file) !== music.sha256.toLowerCase()) await download(music.track, music.sha256, file);
} else if (catalog[music.track]) {
  const t = catalog[music.track];
  const name = `${music.track}.${t.ext ?? extOf(t.url)}`;
  const baked = join(process.env.VIDEO_MUSIC_DIR ?? '/opt/music', name);
  file = join(root, 'raw/music', name);
  if (existsSync(baked) && sha(baked) === t.sha256) file = baked;
  else if (!existsSync(file) || sha(file) !== t.sha256) await download(t.url, t.sha256, file);
  credit ??= t.credit;
  label = `${t.title} by ${t.artist} (${t.license})`;
} else {
  file = isAbsolute(music.track) ? music.track : resolve(root, music.track);
  if (!existsSync(file)) {
    const names = Object.keys(catalog).join(', ');
    throw new Error(`music.track "${music.track}" is not a catalog track (${names}) and no file exists at ${file}`);
  }
}
result({file, credit});
if (credit) writeFileSync(join(root, 'out/music-credit.txt'), `${credit}\n`);
console.log(`music: ${label} (volume ${music.volume}${music.duck ? ', ducked under the voice' : ''})`);
