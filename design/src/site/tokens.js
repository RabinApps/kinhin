// Tokens and components sheet: swatches, type scale, radii, components. Feeds website/src/styles/tokens.css.
function sheet(themeName) {
  const W = 1440, H = 1500; const f = pageFrame("Tokens and components", W, H, { gridH: H });
  text(f, "kinhin.dev design tokens", 80, 60, { size: 44, weight: 700, ls: -3 });
  text(f, "One blue accent. Solid fills only: no gradients, no glows. Geist and Geist Mono.", 80, 120, { size: 17, color: K.mut });
  const sw = (x, y, name, h, a = 1, th = "dark") => { rect(f, x, y, 150, 72, { r: 10, fill: P(h, a), stroke: BORDER(), name }); mono(f, name, x, y + 80, { size: 12, color: K.tx, weight: 500 }); mono(f, h + (a < 1 ? " /" + a : ""), x, y + 98, { size: 11.5, color: K.dim }); };
  mono(f, "DARK", 80, 190, { size: 12, color: K.a1, weight: 500, ls: 8 });
  [["bg", "#05060A"], ["bg-2", "#090B12"], ["surface", "#0D1019"], ["code", "#070910"], ["text", "#EAEEF6"], ["muted", "#8B93A7"], ["dim", "#7A8399"], ["accent", "#3D8BFF"]].forEach(([n, h], i) => sw(80 + i * 168, 216, n, h));
  mono(f, "LIGHT", 80, 350, { size: 12, color: K.a1, weight: 500, ls: 8 });
  [["bg", "#F6F7FB"], ["bg-2", "#EEF0F7"], ["surface", "#FFFFFF"], ["code", "#0F1320"], ["text", "#0B0E14"], ["muted", "#4B5366"], ["dim", "#586179"], ["accent", "#1D5FE0"]].forEach(([n, h], i) => sw(80 + i * 168, 376, n, h));
  mono(f, "Text on tinted surfaces uses a deeper accent in light mode: accent-text #1850C8 (the fill stays #1D5FE0). Dim text: #7A8399 dark, #586179 light.", 80, 490, { size: 12, color: K.mut });
  mono(f, "TYPE", 80, 530, { size: 12, color: K.a1, weight: 500, ls: 8 });
  [["display", 84, 700, "Commit it."], ["h1", 52, 700, "Quick start"], ["h2", 28, 700, "Requirements"], ["lead", 18, 400, "Ephemeral runners that scale to your queue."], ["body", 15.5, 400, "Every job gets a fresh VM or container."], ["label", 12.5, 500, "// WHAT YOU GET"]].forEach(([n, s, w, t], i) => { mono(f, n + " · " + s, 80, 580 + i * 70 + 10, { size: 12, color: K.dim }); text(f, t, 260, 570 + i * 70, { size: Math.min(s, 64), weight: w, ls: s > 40 ? -3 : 0, mono: n === "label", color: n === "label" ? K.a1 : K.tx }); });
  mono(f, "RADIUS / BORDER", 780, 530, { size: 12, color: K.a1, weight: 500, ls: 8 });
  [[8, "button, input"], [12, "code, callout"], [16, "panel, card"], [20, "media"]].forEach(([r, n], i) => { rect(f, 780 + i * 150, 570, 110, 80, { r, fill: P(K.panel, K.pa), stroke: BORDER() }); mono(f, r + "px", 780 + i * 150, 662, { size: 12, color: K.tx }); mono(f, n, 780 + i * 150, 680, { size: 11, color: K.dim }); });
  mono(f, "COMPONENTS", 80, 1010, { size: 12, color: K.a1, weight: 500, ls: 8 });
  button(f, "Get started", 80, 1050, { primary: true, w: 140, h: 48 }); button(f, "CLI reference", 236, 1050, { w: 150, h: 48 });
  chip(f, "BETA", 420, 1060, { color: K.a1 }); chip(f, "online", 500, 1060, { color: K.a1, dot: K.a1 });
  codeBlock(f, 80, 1130, 560, [["$ kinhin start", "#EAEEF6"], ["✓ fleet online", K.a1]], { title: "terminal" });
  const c = frame(f, "Callout", 700, 1050, 620, 92, { r: 12, fill: P(K.a1, 0.08), stroke: P(K.a1, 0.35) }); rect(c, 0, 0, 3, 92, { fill: P(K.a1) }); mono(c, "TIP", 22, 16, { size: 11.5, color: K.a1, weight: 500, ls: 10 }); text(c, "Callouts, tips and warnings all use the same blue treatment.", 22, 40, { size: 15, w: 570 });
  const wn = frame(f, "Callout warning", 700, 1160, 620, 92, { r: 12, fill: P(K.panel, K.pa), stroke: P(K.a1, 0.6) }); rect(wn, 0, 0, 3, 92, { fill: P(K.a1) }); mono(wn, "WARNING", 22, 16, { size: 11.5, color: K.tx, weight: 500, ls: 10 }); text(wn, "Warnings add a stronger outline instead of a new colour.", 22, 40, { size: 15, w: 570 });
  return f;
}
