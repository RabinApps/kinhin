// Screenshots (PNG) as a cross-fading slideshow of one clip, for a clip scene with a `screens` list (scripts/frames.mjs).
import {execFileSync} from 'node:child_process';
import {existsSync} from 'node:fs';

export // Screenshots (PNG) as a slideshow: each image is held for `hold` seconds and cross-fades into the next, and the whole
// clip is trimmed (or its last image held) to the scene's length. Every image is fitted to one frame size first.
function slideshow(images, length, out, {hold = 2.5, fade = 0.5, width = 1170, height = 2532} = {}) {
  if (!images.length) throw new Error('screens: no images');
  for (const image of images) if (!existsSync(image)) throw new Error(`screens: no image "${image}"`);
  const per = Math.max(hold, fade + 0.1);
  const args = ['-nostdin', '-y', '-loglevel', 'error'];
  for (const image of images) args.push('-loop', '1', '-t', String(per), '-i', image);
  const fit = (i) => `[${i}:v]scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2:white,setsar=1,fps=30,format=yuv420p[v${i}]`;
  const graph = [images.map((_, i) => fit(i)).join(';')];
  let last = 'v0';
  let total = per;
  for (let i = 1; i < images.length; i++) {
    const next = `x${i}`;
    graph.push(`[${last}][v${i}]xfade=transition=fade:duration=${fade}:offset=${(total - fade).toFixed(3)}[${next}]`);
    last = next;
    total += per - fade;
  }
  graph.push(`[${last}]tpad=stop_mode=clone:stop_duration=${length},trim=duration=${length},setpts=PTS-STARTPTS[out]`);
  args.push('-filter_complex', graph.join(';'), '-map', '[out]', '-c:v', 'libx264', '-crf', '17', out);
  execFileSync('ffmpeg', args, {stdio: 'inherit'});
  console.log(`wrote ${out} (${images.length} screens)`);
}
