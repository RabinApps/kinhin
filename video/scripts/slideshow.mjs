// Screenshots (PNG) as a cross-fading slideshow of one clip, for a clip scene with a `screens` list (scripts/frames.mjs).
// With a frame ("iphone" or "android") each screenshot sits in a drawn phone: the bezel is made by ffmpeg (no device
// artwork, no logos, so it is safe to publish) and the screenshot shows through the screen. frame "none" fills the canvas.
import {execFileSync} from 'node:child_process';
import {existsSync, mkdirSync} from 'node:fs';
import {join} from 'node:path';

// Phone proportions as a share of the phone's width: the body's aspect, the bezel, and the corner radius.
export const PHONES = {
  iphone: {aspect: 0.47, bezel: 0.035, corner: 0.14, body: '28,28,30'},
  android: {aspect: 0.44, bezel: 0.03, corner: 0.1, body: '20,20,20'},
};

/** The phone's size on a canvas of `canvasH` pixels tall: it fills 90% of the height. */
export function phoneSize(kind, canvasH) {
  const h = Math.round(canvasH * 0.9);
  const w = Math.round(h * PHONES[kind].aspect);
  const b = Math.round(w * PHONES[kind].bezel);
  const r = Math.round(w * PHONES[kind].corner);
  return {w, h, b, r};
}

/**
 * Writes a PNG of the phone: transparent outside the body and transparent where the screen is. A point is inside a rounded
 * rectangle when its distance to the rectangle's core (the rectangle shrunk by the corner radius) is at most the radius.
 */
export function phoneFrame(kind, canvasH, out) {
  const {w, h, b, r} = phoneSize(kind, canvasH);
  const R = r;
  const inRounded = (inset, radius) => {
    const lo = inset + radius;
    return `lte(hypot(X-clip(X\\,${lo}\\,W-${lo})\\,Y-clip(Y\\,${lo}\\,H-${lo}))\\,${radius})`;
  };
  const alpha = `255*${inRounded(0, R)}*(1-${inRounded(b, Math.max(1, r - b))})`;
  const [red, green, blue] = PHONES[kind].body.split(',');
  execFileSync(
    'ffmpeg',
    ['-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', `color=c=black:s=${w}x${h},format=rgba`,
      '-vf', `geq=r=${red}:g=${green}:b=${blue}:a='${alpha}'`, '-frames:v', '1', out],
    {stdio: 'inherit'},
  );
  return out;
}

/**
 * A slideshow of `images`: each is held `hold` seconds, cross-fading into the next over `fade` seconds, and the whole is
 * fitted to `length` seconds (the last image is held when it runs short). Written to `out` at canvasW x canvasH.
 */
export function slideshow(images, length, out, {hold = 2.5, fade = 0.5, frame = 'none', canvasW = 1920, canvasH = 1080, work = 'out/.work'} = {}) {
  if (!images.length) throw new Error('screens: no images');
  for (const image of images) if (!existsSync(image)) throw new Error(`screens: no image "${image}"`);
  if (frame !== 'none' && !PHONES[frame]) throw new Error(`screens: frame must be none, iphone or android, not "${frame}"`);
  mkdirSync(work, {recursive: true});
  const per = Math.max(hold, fade + 0.1);
  const framed = frame !== 'none';
  const phone = framed ? phoneSize(frame, canvasH) : null;
  const screen = framed ? {w: phone.w - 2 * phone.b, h: phone.h - 2 * phone.b} : {w: canvasW, h: canvasH};
  const phoneFile = framed ? phoneFrame(frame, canvasH, join(work, `phone-${frame}-${canvasH}.png`)) : null;

  const args = ['-nostdin', '-y', '-loglevel', 'error'];
  for (const image of images) args.push('-loop', '1', '-t', String(per), '-i', image);
  const F = images.length; // the phone frame's input index, when there is one
  if (framed) args.push('-loop', '1', '-t', String(per), '-i', phoneFile);
  const graph = [];
  if (framed) graph.push(`[${F}:v]format=rgba,split=${images.length}${images.map((_, i) => `[f${i}]`).join('')}`);
  const px = Math.round((canvasW - (phone?.w ?? 0)) / 2);
  const py = Math.round((canvasH - (phone?.h ?? 0)) / 2);
  images.forEach((_, i) => {
    graph.push(
      // A phone screen fills its frame (a cover crop, which trims a sliver of the screenshot's edges); an unframed screenshot
      // is fitted with letterboxing, so nothing it shows is cut off.
      framed
        ? `[${i}:v]scale=${screen.w}:${screen.h}:force_original_aspect_ratio=increase,crop=${screen.w}:${screen.h},setsar=1,format=rgba[s${i}]`
        : `[${i}:v]scale=${screen.w}:${screen.h}:force_original_aspect_ratio=decrease,pad=${screen.w}:${screen.h}:(ow-iw)/2:(oh-ih)/2:color=#f3f4f8,setsar=1,format=rgba[s${i}]`,
    );
    if (framed) {
      graph.push(`color=c=#f3f4f8:s=${canvasW}x${canvasH}:r=30:d=${per},format=rgba[bg${i}]`);
      graph.push(`[bg${i}][s${i}]overlay=x=${px + phone.b}:y=${py + phone.b}[c${i}]`);
      graph.push(`[c${i}][f${i}]overlay=x=${px}:y=${py},format=yuv420p,fps=30[v${i}]`);
    } else {
      graph.push(`[s${i}]format=yuv420p,fps=30[v${i}]`);
    }
  });
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
  console.log(`wrote ${out} (${images.length} screens${framed ? `, ${frame} frame` : ''})`);
  return out;
}
