// Docs page: desktop 1440 (sidebar + article + TOC) and mobile 390.
const SIDE = [
  ["Get started", ["Quick start", "Why kinhin", "Install", "Pick your forge"]],
  ["Run your fleet", ["Runtimes & routing", "Scaling", "Security", "Toolchains"]],
  ["Mobile releases", ["Store screenshots", "Fastlane lanes"]],
  ["Reference", ["CLI commands", "Config", "Troubleshooting"]],
];
function sidebar(f, x, y, w, active) {
  let yy = y;
  SIDE.forEach(([g, items]) => {
    mono(f, g.toUpperCase(), x, yy, { size: 11.5, color: K.dim, weight: 500, ls: 8 }); yy += 28;
    items.forEach((s) => {
      const on = s === active;
      if (on) { rect(f, x - 12, yy - 6, w, 32, { r: 8, fill: P(K.a1, 0.1), name: "active" }); rect(f, x - 12, yy + 2, 2, 16, { fill: P(K.a1), name: "bar" }); }
      text(f, s, x, yy, { size: 14.5, color: on ? K.a1 : K.mut, weight: on ? 500 : 400 }); yy += 32;
    });
    yy += 18;
  });
}
function article(f, x, y, w, mobile) {
  mono(f, "GUIDE / GET STARTED", x, y, { size: 12, color: K.a1, weight: 500, ls: 8 });
  text(f, "Quick start", x, y + 28, { size: mobile ? 36 : 52, weight: 700, ls: -3.5 });
  const act = frame(f, "Page actions", x, y + (mobile ? 88 : 108), mobile ? 350 : 360, 34, {});
  const b1 = frame(act, "Copy markdown", 0, 0, 160, 34, { r: 8, fill: P(K.panel, K.pa), stroke: BORDER() });
  mono(b1, "Copy as Markdown", 0, 9, { size: 12, color: K.mut, w: 160, align: "CENTER" });
  const b2 = frame(act, "View md", 170, 0, 90, 34, { r: 8, fill: P(K.panel, K.pa), stroke: BORDER() });
  mono(b2, "View .md", 0, 9, { size: 12, color: K.mut, w: 90, align: "CENTER" });
  let yy = y + (mobile ? 148 : 168);
  const p = text(f, "Kinhin turns your Apple Silicon Mac into an autoscaling fleet of ephemeral self-hosted CI runners. This page gets you from zero to a working fleet.", x, yy, { size: mobile ? 16 : 18, color: K.mut, lh: mobile ? 26 : 30, w }); yy += p.height + 32;
  text(f, "Requirements", x, yy, { size: 28, weight: 700, ls: -2 }); yy += 48;
  ["Apple Silicon Mac (arm64), macOS 15+", "Tart for macOS runner VMs: kinhin setup repair tart installs it", "An access token for at least one forge: GitHub, Gitea, Forgejo or GitLab CE", "About 60 GB free disk for the base image plus per-VM scratch"].forEach((s) => {
    oval(f, x + 2, yy + 9, 6, 6, { fill: P(K.a1) }); const t = text(f, s, x + 22, yy, { size: 15.5, lh: 25, w: w - 22 }); yy += t.height + 10;
  });
  yy += 18;
  // callout
  const ch = mobile ? 118 : 92;
  const c = frame(f, "Callout tip", x, yy, w, ch, { r: 12, fill: P(K.a1, 0.07), stroke: P(K.a1, 0.35) });
  rect(c, 0, 0, 3, ch, { fill: P(K.a1), name: "bar" });
  mono(c, "TIP", 22, 16, { size: 11.5, color: K.a1, weight: 500, ls: 10 });
  text(c, "One fleet can serve several forges at once. Start with one; you can add more later.", 22, 38, { size: 14.5, color: K.tx, lh: 22, w: w - 44 }); yy += ch + 32;
  text(f, "Install (one line)", x, yy, { size: 28, weight: 700, ls: -2 }); yy += 48;
  const cb = codeBlock(f, x, yy, w, (mobile ? [["curl -fsSL …/install.sh | bash", "#EAEEF6"]] : [["curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/\\", "#EAEEF6"], ["  install.sh | bash", "#EAEEF6"]]), { name: "Code" });
  yy += cb.height + 32;
  text(f, "Pick your forge", x, yy, { size: 28, weight: 700, ls: -2 }); yy += 48;
  const rows = [["Forge", "Scope", "Store it with"], ["GitHub Actions", "owner/name or org", "kinhin auth set"], ["Gitea", "owner/name + instance", "kinhin auth set --gitea"], ["GitLab CE", "group/project + instance", "kinhin auth set --gitlab"]];
  const tb = frame(f, "Table", x, yy, w, rows.length * 44, { r: 12, stroke: BORDER() });
  rows.forEach((r, i) => { if (i) line(tb, 0, i * 44, w, 1, BORDER(), "row"); if (i === 0) rect(tb, 0, 0, w, 44, { fill: P(K.panel, K.pa), name: "head" });
    r.forEach((s, j) => mono(tb, mobile && j === 1 ? "" : s, 18 + j * (w / 3), i * 44 + 14, { size: 12.5, color: i === 0 ? K.dim : K.tx, weight: i === 0 ? 500 : 400 })); });
  yy += rows.length * 44 + 36;
  // prev/next
  const half = (w - 16) / 2;
  [["← Previous", "Why kinhin", 0], ["Next →", "Install", half + 16]].forEach(([k, s, dx]) => {
    const pn = panel(f, "pager", x + dx, yy, half, 76, { r: 12 }); mono(pn, k, 18, 14, { size: 11.5, color: K.dim }); text(pn, s, 18, 36, { size: 17, weight: 500 }); });
  return yy + 76;
}
function desktop(themeName) {
  const W = 1440, H = 1260; const f = pageFrame(`Docs / Desktop / ${themeName}`, W, H, { gridH: 1260 });
  glow(f, 1250, 120, 700, K.a2, K.glow * 0.8, "glow"); glow(f, 330, 60, 600, K.a1, K.glow * 0.6, "glow");
  nav(f, W, { active: 2 });
  line(f, 300, 68, 1, H - 68, BORDER(), "sidebar edge");
  sidebar(f, 40, 108, 230, "Quick start");
  article(f, 360, 112, 720, false);
  // TOC
  line(f, 1160, 124, 1, 200, BORDER(), "toc rail"); rect(f, 1159, 124, 3, 36, { fill: P(K.a1), name: "toc active" });
  mono(f, "ON THIS PAGE", 1184, 120, { size: 11.5, color: K.dim, weight: 500, ls: 8 });
  ["Requirements", "Install (one line)", "Pick your forge", "Start the fleet", "Next steps"].forEach((s, i) => text(f, s, 1184, 150 + i * 30, { size: 13.5, color: i === 0 ? K.a1 : K.mut }));
  return f;
}
function mobile(themeName) {
  const W = 390, H = 1500; const f = pageFrame(`Docs / Mobile / ${themeName}`, W, H, { gridH: 700 });
  glow(f, 330, 80, 420, K.a2, K.glow * 0.8, "glow"); nav(f, W);
  const bar = frame(f, "Docs bar", 0, 68, W, 48, { fill: P(K.panel, K.pa) }); line(bar, 0, 47, W, 1, BORDER(), "b");
  mono(bar, "☰  Get started / Quick start", 20, 16, { size: 12.5, color: K.mut });
  article(f, 20, 148, 350, true);
  return f;
}
