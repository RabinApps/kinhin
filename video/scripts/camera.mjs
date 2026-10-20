// A guided camera for a recorded clip: eased zoom and pan, a spotlight that dims the rest of the screen, and a cursor with
// click rings. Used by scripts/frames.mjs on `device` and `terminal` scenes that set `camera`, `focus` or `cursor`. All of it is
// drawn by ffmpeg on the recording itself, before it goes into its laptop or window, so the frame stays still while the picture
// inside it moves. Every position is 0 to 1 across the recording, so a script reads the same at any size and in any format.
//
//   camera: [{at: 2, zoom: 1.8, to: [0.62, 0.35], move: 0.8}, {at: 5, zoom: 1}]
//       from `at` seconds into the scene the camera moves (`move` seconds, default 0.8) to `zoom` (1 to 4) centred on `to`, then
//       holds; a keyframe without `zoom` or `to` keeps the one before it. The camera starts at zoom 1, centred.
//   focus:  {from: 2, to: 5, box: [0.5, 0.2, 0.8, 0.5], dim: 0.55}    (or a list of them)
//       dims everything outside the box between `from` and `to`, fading in and out; `dim` is how dark, default 0.55.
//   cursor: [{at: 2.2, to: [0.7, 0.3]}, {at: 3, to: [0.7, 0.3], click: true}]
//       a pointer that is at `to` at `at` seconds, travelling there from the point before; `click` adds a ring.
import {execFileSync} from 'node:child_process';

const ROUND = 1000;
const num = (x) => String(Math.round(x * ROUND) / ROUND);
/** Smoothstep: 0 to 1 with no jolt at either end. */
export const smooth = (u) => u * u * (3 - 2 * u);

const MOVE = 0.8; // seconds a camera move takes unless the keyframe says
const TRAVEL = 1; // the longest a cursor takes to get to its next point
const FOCUS_FADE = 0.3;

/**
 * Turns "moves" into the pieces of one value over time: each piece is {a, b, from, to} (eased from `from` to `to` between
 * `a` and `b` seconds); the value holds the last `to` after the last piece and `start` before the first.
 */
function pieces(start, moves) {
  let value = start;
  return moves.map((m) => {
    const piece = {a: m.a, b: m.b, from: value, to: m.to};
    value = m.to;
    return piece;
  });
}

/** The value of a series of pieces at `t` seconds (the reference for the ffmpeg expression below). */
export function valueAt(start, series, t) {
  let value = start;
  for (const p of series) {
    if (t < p.a) return value;
    if (t < p.b) return p.from + (p.to - p.from) * smooth((t - p.a) / (p.b - p.a));
    value = p.to;
  }
  return value;
}

/** The same series as an ffmpeg expression in `t`, as nested if(lt(t,..)) with the smoothstep written out. */
export function expression(start, series) {
  const build = (i) => {
    if (i === series.length) return num(series.length ? series[series.length - 1].to : start);
    const {a, b, from, to} = series[i];
    const u = `((t-${num(a)})/${num(b - a)})`;
    return `if(lt(t,${num(a)}),${num(from)},if(lt(t,${num(b)}),${num(from)}+(${num(to - from)})*${u}*${u}*(3-2*${u}),${build(i + 1)}))`;
  };
  return build(0);
}

/**
 * The camera's zoom and centre over time: three series. A keyframe starts a move at its `at`, which lasts its `move` seconds
 * (never past the next keyframe); the zoom or the centre it does not set stays where it was.
 */
export function cameraSeries(keyframes) {
  const frames = [...keyframes].sort((x, y) => x.at - y.at);
  const state = {zoom: 1, x: 0.5, y: 0.5};
  const moves = {zoom: [], x: [], y: []};
  frames.forEach((k, i) => {
    const b = Math.min(k.at + (k.move ?? MOVE), frames[i + 1]?.at ?? Infinity);
    const target = {zoom: k.zoom ?? state.zoom, x: k.to?.[0] ?? state.x, y: k.to?.[1] ?? state.y};
    for (const key of ['zoom', 'x', 'y']) moves[key].push({a: k.at, b, to: target[key]});
    Object.assign(state, target);
  });
  return {zoom: pieces(1, moves.zoom), x: pieces(0.5, moves.x), y: pieces(0.5, moves.y)};
}

/** The cursor's position over time: it reaches each point at its `at`, setting off up to TRAVEL seconds before. */
export function cursorSeries(points) {
  const list = [...points].sort((x, y) => x.at - y.at);
  const moves = {x: [], y: []};
  list.forEach((p, i) => {
    if (i === 0) return;
    const a = Math.max(list[i - 1].at, p.at - TRAVEL);
    moves.x.push({a, b: p.at, to: p.to[0]});
    moves.y.push({a, b: p.at, to: p.to[1]});
  });
  return {x: pieces(list[0].to[0], moves.x), y: pieces(list[0].to[1], moves.y), start: list[0]};
}

/**
 * The ffmpeg filter graph for one clip: input 0 is the recording (already cut to start at the scene's start), the picture
 * comes out as [out] at `width`x`height`, `length` seconds long, `fps` frames per second. `speed` plays the recording faster or slower.
 */
export function cameraGraph({width, height, length, fps = 30, speed = 1, cover, props}) {
  const {camera, focus, cursor} = props;
  // `cover` is the colour of the app window's toolbar: the laptop frame hides the window's buttons with a patch of it, which has to
  // be done here, on the unzoomed picture, or the patch would land on whatever the zoom puts at that corner.
  const patch = cover ? `,drawbox=x=14:y=6:w=130:h=48:color=${cover}:t=fill` : '';
  const steps = [`[0:v]setpts=(PTS-STARTPTS)/${speed},fps=${fps},tpad=stop_mode=clone:stop_duration=30,trim=duration=${length},setpts=PTS-STARTPTS,format=rgba${patch}[c0]`];
  let label = 'c0';
  let n = 0;
  const overlay = (input, position) => {
    const next = `c${++n}`;
    steps.push(`[${label}][${input}]overlay=${position}:format=auto:eof_action=pass[${next}]`);
    label = next;
  };

  // The spotlight: a dark layer a sixteenth of the size (scaled up, so its edge is soft) with the box cut out, fading in and out.
  const spots = focus === undefined ? [] : Array.isArray(focus) ? focus : [focus];
  spots.forEach((f, i) => {
    const w = Math.max(2, Math.round(width / 16));
    const h = Math.max(2, Math.round(height / 16));
    const [x0, y0, x1, y1] = f.box;
    const ramp = `clip(min((T-${num(f.from)})/${FOCUS_FADE},(${num(f.to)}-T)/${FOCUS_FADE}),0,1)`;
    const inside = `between(X,${num(x0 * w)},${num(x1 * w)})*between(Y,${num(y0 * h)},${num(y1 * h)})`;
    steps.push(
      `color=c=black:s=${w}x${h}:r=${fps}:d=${length},format=gbrap,geq=r=0:g=0:b=0:a='${num((f.dim ?? 0.55) * 255)}*${ramp}*(1-${inside})',format=rgba,scale=${width}:${height}:flags=bicubic[s${i}]`,
    );
    overlay(`s${i}`, '0:0');
  });

  // The cursor: a white dot with a dark rim that travels between points, and a ring that spreads from each click.
  if (cursor !== undefined) {
    const R = Math.max(5, Math.round(height * 0.011));
    const D = 2 * R + 4;
    const c = D / 2;
    const path = cursorSeries(cursor);
    const tint = `format=gbrap,geq=r='if(gt(hypot(X-${c},Y-${c}),${R - 2}),20,255)':g='if(gt(hypot(X-${c},Y-${c}),${R - 2}),20,255)':b='if(gt(hypot(X-${c},Y-${c}),${R - 2}),20,255)':a='255*clip(${R}+0.5-hypot(X-${c},Y-${c}),0,1)',format=rgba`;
    steps.push(`color=c=black:s=${D}x${D}:r=${fps}:d=${length},${tint}[dot]`);
    const px = `(${expression(path.start.to[0], path.x)})*${width}-${c}`;
    const py = `(${expression(path.start.to[1], path.y)})*${height}-${c}`;
    for (const [i, p] of cursor.filter((k) => k.click).entries()) {
      const S = R * 8;
      const mid = S / 2;
      const u = `clip(T/0.45,0,1)`;
      const radius = `(${R}*(1+2.4*${u}))`;
      steps.push(
        `color=c=black:s=${S}x${S}:r=${fps}:d=0.45,format=gbrap,geq=r=255:g=255:b=255:a='255*0.85*(1-${u})*clip(2-abs(hypot(X-${mid},Y-${mid})-${radius})/1.4,0,1)',format=rgba,setpts=PTS+${num(p.at)}/TB[ring${i}]`,
      );
      overlay(`ring${i}`, `${num(p.to[0] * width - mid)}:${num(p.to[1] * height - mid)}:enable='between(t,${num(p.at)},${num(p.at + 0.45)})'`);
    }
    // Last, so the dot sits above the rings; it shows from the first point.
    overlay('dot', `x='${px}':y='${py}':eval=frame:enable='gte(t,${num(path.start.at)})'`);
  }

  // The camera: scale the picture up by the zoom, then crop the window of the original size around the centre, kept inside the
  // picture. The scaled size is written out here, not read as iw and ih: crop only knows the size its input had at the start.
  if (camera !== undefined) {
    const s = cameraSeries(camera);
    const zoom = expression(1, s.zoom);
    const scaledW = `(trunc(${width}*(${zoom})/2)*2)`;
    const scaledH = `(trunc(${height}*(${zoom})/2)*2)`;
    steps.push(
      `[${label}]scale=w='${scaledW}':h='${scaledH}':eval=frame:flags=bicubic,` +
        `crop=${width}:${height}:x='clip((${expression(0.5, s.x)})*${scaledW}-${width / 2},0,${scaledW}-${width})':y='clip((${expression(0.5, s.y)})*${scaledH}-${height / 2},0,${scaledH}-${height})'[zoomed]`,
    );
    label = 'zoomed';
  }
  steps.push(`[${label}]format=yuv420p[out]`);
  return steps.join(';');
}

/** The width and height of a video file's first stream. */
export function probeSize(file) {
  const [width, height] = execFileSync('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=p=0:s=x', file]).toString().trim().split('x').map(Number);
  return {width, height};
}

/** True when a clip scene's props ask for any camera work. */
export const wantsCamera = (props) => ['camera', 'focus', 'cursor'].some((k) => props?.[k] !== undefined);

/**
 * Writes `out`: `length` seconds of `clip` (from `start`, at `speed`) with the camera work in `props` applied, at the clip's own
 * size. The scene's frame (frames.mjs) then takes it as an ordinary clip that starts at 0 and plays at normal speed.
 */
export function applyCamera({clip, out, props, start = 0, speed = 1, length, fps = 30, cover}) {
  const {width, height} = probeSize(clip);
  const graph = cameraGraph({width, height, length, fps, speed, cover, props});
  execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-ss', String(start), '-t', String(length * speed), '-i', clip, '-filter_complex', graph, '-map', '[out]', '-an', '-c:v', 'libx264', '-crf', '16', '-pix_fmt', 'yuv420p', out], {stdio: 'inherit'});
  console.log(`wrote ${out}`);
}
