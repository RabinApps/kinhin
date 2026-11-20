// Helpers for the kinhin.dev design. Concatenated in front of each page script by build.mjs and run
// with `openpencil eval` (Figma plugin API). Everything is absolutely positioned; text reports its height.
const THEMES = {
  dark: { bg: "#05060A", bg2: "#090B12", surf: "#0D1019", border: "#FFFFFF", ba: 0.09, tx: "#EAEEF6", mut: "#8B93A7", dim: "#7A8399",
          a1: "#3D8BFF", a2: "#3D8BFF", ok: "#7DB2FF", warn: "#7DB2FF", err: "#7DB2FF", grid: "#FFFFFF", ga: 0.035, glow: 0.22, panel: "#FFFFFF", pa: 0.04, code: "#070910" },
  light: { bg: "#F6F7FB", bg2: "#EEF0F7", surf: "#FFFFFF", border: "#0B0E14", ba: 0.1, tx: "#0B0E14", mut: "#4B5366", dim: "#586179", a1: "#1D5FE0", a2: "#1D5FE0",
           ok: "#1D5FE0", warn: "#1D5FE0", err: "#1D5FE0", grid: "#0B0E14", ga: 0.05, glow: 0.14, panel: "#0B0E14", pa: 0.035, code: "#0F1320" },
};
let K = THEMES.dark;
const setTheme = (n) => { K = THEMES[n]; };
const hex = (h) => ({ r: parseInt(h.slice(1, 3), 16) / 255, g: parseInt(h.slice(3, 5), 16) / 255, b: parseInt(h.slice(5, 7), 16) / 255 });
const P = (h, a = 1) => ({ type: "SOLID", color: hex(h), opacity: a });
const GT = { h: { m00: 1, m01: 0, m02: 0, m10: 0, m11: 1, m12: 0 }, v: { m00: 0, m01: 1, m02: 0, m10: -1, m11: 0, m12: 1 }, d: { m00: 0.7, m01: 0.7, m02: 0, m10: -0.7, m11: 0.7, m12: 0.5 } };
const GL = (stops) => P(stops[stops.length > 1 ? 1 : 0][1], 1); // no gradients in this design: solid only
const GR = (h, a) => P(h, a);
const BORDER = () => P(K.border, K.ba);
const ACC = () => P(K.a1);

const FONTS = [["Geist", "Regular"], ["Geist", "Medium"], ["Geist", "Bold"], ["GeistMono", "Regular"], ["GeistMono", "Medium"]];
async function loadFonts() { for (const [family, style] of FONTS) await figma.loadFontAsync({ family, style }); }

function frame(parent, name, x, y, w, h, o = {}) {
  const f = figma.createFrame(); f.name = name; f.x = x; f.y = y; f.resize(w, h);
  f.fills = o.fill === undefined ? [] : Array.isArray(o.fill) ? o.fill : [o.fill];
  f.clipsContent = o.clip !== false; if (o.r) f.cornerRadius = o.r;
  if (o.stroke) { f.strokes = [o.stroke]; f.strokeWeight = o.sw || 1; }
  if (o.fx) f.effects = o.fx;
  parent.appendChild(f); return f;
}
function rect(parent, x, y, w, h, o = {}) {
  const r = figma.createRectangle(); r.name = o.name || "Rectangle"; r.x = x; r.y = y; r.resize(w, h);
  r.fills = o.fill === undefined ? [] : Array.isArray(o.fill) ? o.fill : [o.fill];
  if (o.r) r.cornerRadius = o.r;
  if (o.stroke) { r.strokes = [o.stroke]; r.strokeWeight = o.sw || 1; }
  if (o.fx) r.effects = o.fx; if (o.op !== undefined) r.opacity = o.op;
  parent.appendChild(r); return r;
}
function oval(parent, x, y, w, h, o = {}) {
  const e = figma.createEllipse(); e.name = o.name || "Ellipse"; e.x = x; e.y = y; e.resize(w, h);
  e.fills = o.fill === undefined ? [] : Array.isArray(o.fill) ? o.fill : [o.fill];
  if (o.stroke) { e.strokes = [o.stroke]; e.strokeWeight = o.sw || 1; }
  if (o.fx) e.effects = o.fx; if (o.op !== undefined) e.opacity = o.op;
  parent.appendChild(e); return e;
}
const shadow = (h, a, r, y = 0) => ({ type: "DROP_SHADOW", color: { ...hex(h), a }, offset: { x: 0, y }, radius: r, spread: 0, visible: true, blendMode: "NORMAL" });
const glow = () => null; // glows are gradients: not used
function line(parent, x, y, w, h, fill, name = "Line") { return rect(parent, x, y, w, h, { fill, name }); }
function grid(parent, w, h, step = 56, name = "Grid") {
  const g = frame(parent, name, 0, 0, w, h, {});
  for (let x = 0; x <= w; x += step) line(g, x, 0, 1, h, P(K.grid, K.ga), "v");
  for (let y = 0; y <= h; y += step) line(g, 0, y, w, 1, P(K.grid, K.ga), "h");
  return g;
}
function vec(parent, d, o = {}) {
  const v = figma.createVector(); v.name = o.name || "Vector"; v.vectorPaths = [{ windingRule: "NONE", data: d }];
  v.strokes = [o.stroke || P(K.a1)]; v.strokeWeight = o.sw || 2; v.fills = []; v.x = o.x || 0; v.y = o.y || 0; if (o.op !== undefined) v.opacity = o.op;
  parent.appendChild(v); return v;
}
// text(parent, str, x, y, {size, w, weight: 400|500|700, mono, color, a, lh, ls, align, gradient})
function text(parent, s, x, y, o = {}) {
  const t = figma.createText(); const wt = o.weight >= 700 ? "Bold" : o.weight >= 500 ? "Medium" : "Regular";
  t.fontName = { family: o.mono ? "GeistMono" : "Geist", style: o.mono && wt === "Bold" ? "Medium" : wt };
  t.characters = s; t.fontSize = o.size || 16; t.x = x; t.y = y;
  t.fills = [o.gradient || P(o.color || K.tx, o.a === undefined ? 1 : o.a)];
  if (o.lh) t.lineHeight = { value: o.lh, unit: "PIXELS" };
  if (o.ls !== undefined) t.letterSpacing = { value: o.ls, unit: "PERCENT" };
  if (o.align) t.textAlignHorizontal = o.align;
  if (o.w) { t.resize(o.w, Math.max(t.height, 10)); t.textAutoResize = "HEIGHT"; }
  t.name = o.name || s.slice(0, 40);
  parent.appendChild(t); return t;
}
const mono = (parent, s, x, y, o = {}) => text(parent, s, x, y, { mono: true, ...o });

function logoMark(parent, x, y, s, color) {
  // the kinhin ring: stroke circle (mark.svg is r=18.25 stroke 3.5 in a 64 box)
  const d = s * (36.5 / 64), sw = s * (3.5 / 64);
  return oval(parent, x + (s - d) / 2, y + (s - d) / 2, d, d, { stroke: P(color || K.a1), sw, name: "Ring" });
}
function chip(parent, s, x, y, o = {}) {
  const c = o.color || K.a1; const wd = Math.ceil(s.length * (o.mono === false ? 7 : 7.4)) + 24;
  const f = frame(parent, "Chip", x, y, wd, 26, { r: 13, fill: P(c, 0.1), stroke: P(c, 0.35) });
  if (o.dot) oval(f, 10, 10, 6, 6, { fill: P(o.dot), name: "dot" });
  mono(f, s, o.dot ? 22 : 12, 6, { size: 12, color: c, weight: 500 });
  if (o.dot) f.resize(wd + 12, 26);
  return f;
}
function button(parent, s, x, y, o = {}) {
  const w = o.w || Math.ceil(s.length * 8.4) + 44, h = o.h || 44;
  if (o.primary) {
    const f = frame(parent, "Button", x, y, w, h, { r: 10, fill: ACC() });
    text(f, s, 0, (h - 20) / 2, { size: 15, weight: 500, color: "#04060B", w, align: "CENTER" }); return f;
  }
  const f = frame(parent, "Button", x, y, w, h, { r: 10, fill: P(K.panel, K.pa), stroke: BORDER() });
  text(f, s, 0, (h - 20) / 2, { size: 15, weight: 500, w, align: "CENTER" }); return f;
}
function panel(parent, name, x, y, w, h, o = {}) {
  return frame(parent, name, x, y, w, h, { r: o.r === undefined ? 16 : o.r, fill: o.fill || P(K.panel, K.pa), stroke: o.stroke || BORDER(), clip: o.clip, fx: o.fx });
}
// terminal / code block. lines: array of [text, color?]
function codeBlock(parent, x, y, w, lines, o = {}) {
  const lh = 22, pad = 18, head = o.title ? 38 : 0, h = lines.length * lh + pad * 2 + head;
  const f = frame(parent, o.name || "Code", x, y, w, h, { r: 12, fill: P(K.code), stroke: BORDER(),  });
  if (o.title) {
    line(f, 0, head - 1, w, 1, BORDER(), "sep");
    for (let i = 0; i < 3; i++) oval(f, 16 + i * 16, 13, 10, 10, { fill: P("#FFFFFF", 0.18) });
    mono(f, o.title, 0, 11, { size: 12, color: "#8B93A7", w, align: "CENTER" });
  }
  lines.forEach((l, i) => {
    const [s, c] = Array.isArray(l) ? l : [l];
    mono(f, s, pad, head + pad + i * lh, { size: 13.5, color: c || "#C8D0E0", lh });
  });
  return f;
}
function nav(parent, w, o = {}) {
  const h = 68; const f = frame(parent, "Nav", 0, 0, w, h, { fill: P(K.bg, 0.72) });
  line(f, 0, h - 1, w, 1, BORDER(), "border");
  const px = w < 600 ? 20 : 40;
  logoMark(f, px - 6, 18, 32); text(f, "kinhin", px + 30, 21, { size: 19, weight: 700, ls: -2 });
  if (w >= 600) {
    chip(f, "BETA", px + 112, 21, { color: K.a2 });
    ["Guide", "Blog", "Docs"].forEach((s, i) => mono(f, s, px + 196 + i * 72, 24, { size: 13.5, color: i === (o.active ?? -1) ? K.tx : K.mut, weight: 500 }));
    const gh = frame(f, "Stars", w - px - 330, 16, 120, 36, { r: 8, fill: P(K.panel, K.pa), stroke: BORDER() });
    mono(gh, "★ 1.2k", 0, 10, { size: 13, color: K.mut, w: 120, align: "CENTER" });
    const sr = frame(f, "Search", w - px - 200, 16, 90, 36, { r: 8, fill: P(K.panel, K.pa), stroke: BORDER() });
    mono(sr, "⌘ K", 0, 10, { size: 13, color: K.mut, w: 90, align: "CENTER" });
    const dl = frame(f, "Download", w - px - 100, 16, 110, 36, { r: 10, fill: ACC() });
    text(dl, "Download", 0, 8, { size: 14, weight: 500, color: "#04060B", w: 110, align: "CENTER" });
  } else {
    rect(f, w - px - 22, 28, 22, 2, { fill: P(K.tx) }); rect(f, w - px - 22, 38, 22, 2, { fill: P(K.tx) });
    mono(f, "⌘K", w - px - 70, 24, { size: 13, color: K.mut });
  }
  return f;
}
function pageFrame(name, w, h, o = {}) {
  const f = figma.createFrame(); f.name = name; f.resize(w, h); f.x = o.x || 0; f.y = o.y || 0; f.fills = [P(K.bg)]; f.clipsContent = true;
  figma.currentPage.appendChild(f);
  if (o.grid !== false) grid(f, w, Math.min(h, o.gridH || 900), 56);
  return f;
}
