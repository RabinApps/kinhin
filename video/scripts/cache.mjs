// Content-addressed caches for the slow, repeatable steps of a build (the voice, the framed clips). A cache lives under raw/,
// which `kinhin video build` keeps between runs (out/.work does not), and a result is reused only when everything that shapes it
// hashes the same, so a hit is the file the step would have made again.
import {createHash} from 'node:crypto';
import {closeSync, copyFileSync, existsSync, mkdirSync, openSync, readFileSync, readSync, readdirSync, statSync, utimesSync, writeFileSync, rmSync} from 'node:fs';
import {join} from 'node:path';

/** sha256 of a string, or of a value as JSON (object keys in the order given: build the value the same way every time). */
export const sha = (value) => createHash('sha256').update(typeof value === 'string' ? value : JSON.stringify(value)).digest('hex');

/** sha256 of a file's bytes, read in chunks so a long recording is not held in memory. */
export function hashFile(file) {
  const hash = createHash('sha256');
  const buffer = Buffer.alloc(1 << 20);
  const fd = openSync(file, 'r');
  try {
    for (let n = readSync(fd, buffer, 0, buffer.length, null); n > 0; n = readSync(fd, buffer, 0, buffer.length, null)) hash.update(buffer.subarray(0, n));
  } finally {
    closeSync(fd);
  }
  return hash.digest('hex');
}

/**
 * sha256 of a file, remembered by its path, size and modification time in `store` (a plain object the caller keeps in a JSON file),
 * so a long recording is read once and not on every build. The file's bytes are read again when its size or time changes.
 */
export function hashFileOnce(file, store) {
  const {size, mtimeMs} = statSync(file);
  const known = store[file];
  if (known && known.size === size && known.mtimeMs === mtimeMs) return known.sha;
  const sha = hashFile(file);
  store[file] = {size, mtimeMs, sha};
  return sha;
}

export const readJson = (file, fallback = {}) => (existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : fallback);
export const writeJson = (file, value) => writeFileSync(file, JSON.stringify(value, null, 2) + '\n');

/** The key of one spoken cue: everything that changes how it sounds. `speed` is the engine's own rate. */
export const voiceKey = ({engine, model, voice, speed, text}) => sha({engine, model, voice, speed, text});

/** Removes the files of `dir` not used for `days` days (a hit refreshes a file's time), so a cache does not grow for ever. */
export function prune(dir, days = 30) {
  if (!existsSync(dir)) return 0;
  const cutoff = Date.now() - days * 86400000;
  let removed = 0;
  for (const name of readdirSync(dir)) {
    if (statSync(join(dir, name)).mtimeMs < cutoff) {
      rmSync(join(dir, name), {force: true});
      removed++;
    }
  }
  return removed;
}

/** Prunes every folder of `dir` (one per project) of files not used for `days` days, and removes the folders that end up empty. */
export function pruneFolders(dir, days = 60) {
  if (!existsSync(dir)) return 0;
  let removed = 0;
  for (const name of readdirSync(dir)) {
    const folder = join(dir, name);
    if (!statSync(folder).isDirectory()) continue;
    removed += prune(folder, days);
    if (readdirSync(folder).length === 0) rmSync(folder, {recursive: true, force: true});
  }
  return removed;
}

/**
 * Gives each job its `seconds`. A job is {out, ...}: when `dir` holds an entry for `key(job)` it is copied to `job.out`; every
 * other job goes to `render(misses)`, which writes each `out` and returns the durations in order, and the results are stored.
 * `seconds(file)` measures a cached file. `force` skips the lookup (the results are still stored). Returns {hits, misses}.
 */
export async function withCache(jobs, {dir, force = false, key, render, seconds}) {
  mkdirSync(dir, {recursive: true});
  const misses = [];
  for (const job of jobs) {
    const entry = join(dir, `${key(job)}.m4a`);
    job.entry = entry;
    if (!force && existsSync(entry)) {
      copyFileSync(entry, job.out);
      utimesSync(entry, new Date(), new Date()); // used: keep it out of the prune
      job.seconds = seconds(job.out);
    } else {
      misses.push(job);
    }
  }
  if (misses.length) {
    const durations = await render(misses);
    misses.forEach((job, i) => {
      job.seconds = durations[i];
      copyFileSync(job.out, job.entry);
    });
  }
  return {hits: jobs.length - misses.length, misses: misses.length};
}

/**
 * The key of one framed clip scene: what it shows (`type`, `props`, the clip's `targets`), how long it lasts, the look (sizes, colours,
 * platform), the content of every recording and image it uses (`files`, hashed) and of the framing code itself (`code`).
 */
export const frameKey = ({type, props, targets, length, look, files, code}) => sha({type, props, targets, length, look, files, code});
