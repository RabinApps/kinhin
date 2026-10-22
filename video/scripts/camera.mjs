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
//   speed: a list of {until, speed} segments plays the recording with speed ramps (scripts/speed.mjs).
//   Anywhere a point or a box is wanted, a name from the clip's `targets` in its adapter does as well (resolveTargets below):
//   `camera: [{at: 2, target: "fleet"}]` zooms to fit the box named fleet, `focus: {box: "fleet"}` spotlights it.
//   autoZoom: true (or {zoom, lead, hold, gap, reach}) follows the clicks in the clip's pointer log (autoCamera below): the camera
//       zooms in on each burst of clicks and back out. The log is `<clip>-pointer.json`, written by `kinhin video record --pointer`.
//       It is camera work of its own, so it does not go with `camera`.
import {execFileSync} from 'node:child_process';
import {existsSync, readFileSync} from 'node:fs';
import {sourceSeconds, speedFilter, speedPieces} from './speed.mjs';

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
  // A speed list cuts the recording into pieces and plays each at its own speed; a number is one setpts.
  const ramped = Array.isArray(props.speed);
  const steps = ramped ? [speedFilter(speedPieces(props.speed, props.ramp), fps)] : [];
  steps.push(`${ramped ? '[sp]' : '[0:v]'}${ramped ? '' : `setpts=(PTS-STARTPTS)/${speed},`}fps=${fps},tpad=stop_mode=clone:stop_duration=30,trim=duration=${length},setpts=PTS-STARTPTS,format=rgba${patch}[c0]`);
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

const FIT = 0.92; // a target fills this much of the view when the camera zooms to it
const centre = (box) => [(box[0] + box[2]) / 2, (box[1] + box[3]) / 2];

/** The names a clip's props point at (from `camera`, `focus` and `cursor`), to check them against the adapter's `targets`. */
export function targetNames(props) {
  const names = new Set();
  const add = (v) => { if (typeof v === 'string') names.add(v); };
  for (const k of props?.camera ?? []) { add(k.target); add(k.to); }
  for (const f of [].concat(props?.focus ?? [])) add(f.box);
  for (const k of props?.cursor ?? []) add(k.to);
  return [...names];
}

/**
 * Replaces the target names in a clip's props with numbers, so cameraGraph sees only coordinates. `targets` is the clip's
 * `targets` in its adapter: {name: [x0, y0, x1, y1]}. A camera keyframe's `target` zooms to fit the box (unless it gives its
 * own `zoom`) and centres on it; as a point (`to`, a cursor's `to`) a name means the box's centre. Throws on an unknown name.
 */
export function resolveTargets(props, targets = {}, clip = 'the clip') {
  const box = (name) => {
    const b = targets[name];
    if (!(Array.isArray(b) && b.length === 4 && b.every((v) => typeof v === 'number' && v >= 0 && v <= 1) && b[2] > b[0] && b[3] > b[1])) {
      const known = Object.keys(targets);
      throw new Error(`${clip} has no target "${name}"${known.length ? ` (it has: ${known.join(', ')})` : ' (add "targets": {"name": [x0, y0, x1, y1]} to the clip in its adapter)'}`);
    }
    return b;
  };
  const point = (v) => (typeof v === 'string' ? centre(box(v)) : v);
  const out = {...props};
  if (props.camera) {
    out.camera = props.camera.map(({target, ...k}) => {
      if (target === undefined) return {...k, ...(k.to !== undefined && {to: point(k.to)})};
      const b = box(target);
      return {zoom: Math.min(4, Math.max(1, Math.min(1 / (b[2] - b[0]), 1 / (b[3] - b[1])) * FIT)), ...k, to: centre(b)};
    });
  }
  if (props.focus) {
    const resolve = (f) => ({...f, box: typeof f.box === 'string' ? box(f.box) : f.box});
    out.focus = Array.isArray(props.focus) ? props.focus.map(resolve) : resolve(props.focus);
  }
  if (props.cursor) out.cursor = props.cursor.map((k) => ({...k, to: point(k.to)}));
  return out;
}

/** The width and height of a video file's first stream. */
export function probeSize(file) {
  const [width, height] = execFileSync('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=p=0:s=x', file]).toString().trim().split('x').map(Number);
  return {width, height};
}

/** True when a clip's props need the pre-pass: camera work, or a speed list (a constant speed is the laptop frame's own). */
export const wantsCamera = (props) => ['camera', 'focus', 'cursor', 'autoZoom'].some((k) => props?.[k] !== undefined) || Array.isArray(props?.speed);

const AUTO = {zoom: 1.6, lead: 0.6, hold: 1.5, gap: 3, reach: 0.35, move: 0.6};

/**
 * Where a point `c` seconds into a recording lands in the scene, given the clip's pace: a constant speed (a number), or a speed
 * list, in which case `ramp` is its ease (scripts/speed.mjs). Counted from the same start as `c`.
 */
export function sceneTime(c, pace = 1, ramp) {
  if (!Array.isArray(pace)) return c / Number(pace);
  let out = 0;
  for (const p of speedPieces(pace, ramp)) {
    if (c < p.to) return out + (c - p.from) / p.speed;
    out += (p.to - p.from) / p.speed;
  }
  return out;
}

/**
 * Camera keyframes that follow a recording's clicks ({t, x, y}: seconds into the clip, and the point 0 to 1 across it). Clicks that
 * come close in time and place form one group. Each group zooms in on its centre `lead` seconds before its first click, holds
 * `hold` seconds after its last, and zooms back out, unless the next group starts before that (then it zooms straight on).
 * `cut` is where the scene's story starts in the clip, `pace` and `ramp` how it plays, `length` the scene's length in seconds.
 * Returns [] when no click falls in the scene.
 */
export function autoCamera(clicks, {cut = 0, pace = 1, ramp, length, zoom = AUTO.zoom, lead = AUTO.lead, hold = AUTO.hold, gap = AUTO.gap, reach = AUTO.reach, move = AUTO.move} = {}) {
  const at = clicks
    .filter((c) => c.t >= cut)
    .map((c) => ({at: sceneTime(c.t - cut, pace, ramp), x: c.x, y: c.y}))
    .filter((c) => c.at <= length)
    .sort((a, b) => a.at - b.at);
  const groups = [];
  for (const c of at) {
    const last = groups[groups.length - 1];
    const near = last && c.at - last.end <= gap && Math.hypot(c.x - last.first.x, c.y - last.first.y) <= reach;
    if (near) {
      last.end = c.at;
      last.points.push(c);
    } else groups.push({first: c, end: c.at, points: [c]});
  }
  const keys = [];
  groups.forEach((g, i) => {
    const x = g.points.reduce((sum, p) => sum + p.x, 0) / g.points.length;
    const y = g.points.reduce((sum, p) => sum + p.y, 0) / g.points.length;
    keys.push({at: Math.max(0, g.first.at - lead), zoom: Math.min(4, Math.max(1, zoom)), to: [x, y], move});
    const out = g.end + hold;
    if (groups[i + 1] === undefined || groups[i + 1].first.at - lead > out) keys.push({at: out, zoom: 1, to: [0.5, 0.5], move});
  });
  return keys;
}

/** The pointer log that goes with a recording: `<name>-pointer.json` beside it (raw or reference), from `--pointer`. */
export const pointerFileOf = (file) => file.replace(/\.[^./]+$/, '-pointer.json');

/**
 * The scene's props with its `autoZoom` turned into `camera` keyframes, read from the pointer log beside the recording `file`
 * (`cut`, `pace` and `length` as autoCamera takes them). Props without autoZoom come back as they are. Throws when the scene also
 * has a `camera`, or the log is missing. A log with no click in the scene gives no keyframes, so the camera stays where it is.
 */
export function autoZoomSpec(spec, {file, cut = 0, pace = 1, length, where = 'the scene'}) {
  if (spec.autoZoom === undefined) return spec;
  if (spec.camera !== undefined) throw new Error(`${where}: "camera" and "autoZoom" both move the camera; keep one`);
  const log = pointerFileOf(file);
  if (!existsSync(log)) throw new Error(`${where}: autoZoom needs ${log}; record the clip with --pointer (record-app.sh does it)`);
  const clicks = JSON.parse(readFileSync(log, 'utf8')).clicks;
  const keys = autoCamera(clicks, {...(typeof spec.autoZoom === 'object' ? spec.autoZoom : {}), cut, pace, ramp: spec.ramp, length});
  return keys.length ? {...spec, camera: keys} : spec;
}

/**
 * Writes `out`: `length` seconds of `clip` (from `start`, at `speed`) with the camera work in `props` applied, at the clip's own
 * size. The scene's frame (frames.mjs) then takes it as an ordinary clip that starts at 0 and plays at normal speed.
 */
export function applyCamera({clip, out, props, start = 0, speed = 1, length, fps = 30, cover}) {
  const {width, height} = probeSize(clip);
  const graph = cameraGraph({width, height, length, fps, speed, cover, props});
  const seconds = Array.isArray(props.speed) ? sourceSeconds(props.speed, length, props.ramp) : length * speed;
  execFileSync('ffmpeg', ['-nostdin', '-y', '-loglevel', 'error', '-ss', String(start), '-t', String(seconds), '-i', clip, '-filter_complex', graph, '-map', '[out]', '-an', '-c:v', 'libx264', '-crf', '16', '-pix_fmt', 'yuv420p', out], {stdio: 'inherit'});
  console.log(`wrote ${out}`);
}
