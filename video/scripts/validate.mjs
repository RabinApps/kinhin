#!/usr/bin/env node
// Checks your videos without rendering them: the same checks the build makes before it starts (the project file, its theme,
// format, captions and music, the text limits, the claims), plus the things a build only finds later: that each device or
// terminal scene's clip exists in its adapter, and that a music file is in the repository. Runs in the video image, against
// your repository (VIDEO_SOURCE), so `kinhin video validate` and the build cannot disagree.
//
// Usage: node scripts/validate.mjs [--project NAME | --all]      Exit 1 when a video has a problem.
import {existsSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {loadAdapter, resolveClip} from './adapter.mjs';
import {claimsFor, lintProject} from './video-claims-lint.mjs';
import {adapterFile, listSourceProjects, loadProject, sourceDir} from './project.mjs';
import {isNarrow} from '../shared/resolve.mjs';

const CLIP_SCENES = new Set(['device', 'terminal']);
const LOCAL_AUDIO = /\.(mp3|m4a|wav|flac|ogg)$/i;

/** Every problem with one video, in words, with where it is. An empty list means the build can start. */
export function validateVideo(name) {
  let loaded;
  try {
    loaded = loadProject(name);
  } catch (e) {
    return {adapter: null, problems: [e.message]};
  }
  const problems = [];
  const {project, theme, format, adapter: adapterName} = loaded;

  let adapter = null;
  if (adapterName) {
    if (!adapterFile(adapterName)) problems.push(`no adapter "${adapterName}" (add .kinhin/videos/adapters/${adapterName}/adapter.yml)`);
    else adapter = loadAdapter(adapterName);
  }

  try {
    problems.push(...lintProject(project, claimsFor(loaded)));
  } catch (e) {
    problems.push(`claims: ${e.message}`);
  }

  // A device or terminal scene shows a recording: the adapter must declare the clip and have a file for this look.
  const dark = theme.device.terminal === 'dark';
  const narrow = isNarrow(format);
  for (const scene of loaded.scenes) {
    if (!CLIP_SCENES.has(scene.type)) continue;
    const where = `scene "${scene.id}"`;
    const clip = scene.props.clip;
    if (!clip) problems.push(`${where}: a ${scene.type} scene needs props.clip (a clip of its adapter)`);
    else if (!adapter) problems.push(`${where}: clip "${clip}" needs an "adapter" in the video's file`);
    else if (!adapter.manifest.clips?.[clip]) problems.push(`${where}: no clip "${clip}" in the ${adapter.name} adapter`);
    else if (!resolveClip(adapter, clip, {dark, narrow})) {
      problems.push(`${where}: no recording for clip "${clip}". Put it at ${adapter.referenceDir}/${clip}.mp4 (or a variant for this look)`);
    }
  }

  // A music file is read from the repository at build time; check it now.
  const {enabled, track} = loaded.music;
  if (enabled && track && !/^https?:\/\//.test(track) && LOCAL_AUDIO.test(track)) {
    const file = resolve(sourceDir() ?? '', track);
    if (!existsSync(file)) problems.push(`music track "${track}" is not in your repository (paths are relative to it)`);
  }

  return {adapter: adapter?.name ?? null, problems};
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const at = args.indexOf('--project');
  const names = args.includes('--all') ? listSourceProjects() : [(at >= 0 && args[at + 1]) || process.env.VIDEO_PROJECT || 'launch'];
  if (names.length === 0) {
    console.log('no videos in .kinhin/videos/. Create one with `kinhin video init`.');
    process.exit(1);
  }
  let failed = 0;
  for (const name of names) {
    const {adapter, problems} = validateVideo(name);
    console.log(`${problems.length ? 'FAIL' : 'ok  '} ${name}${adapter ? ` (${adapter})` : ''}`);
    for (const p of problems) console.log(`       ${p}`);
    if (problems.length) failed++;
  }
  console.log(
    failed
      ? `\n${failed} of ${names.length} video(s) have problems. Nothing was rendered.`
      : `\n${names.length} video(s) ok. Nothing was rendered.`,
  );
  process.exit(failed ? 1 : 0);
}
