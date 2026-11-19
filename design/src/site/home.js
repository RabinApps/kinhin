// Home page, desktop 1440 and mobile 390. build.mjs appends the calls.

function featureCard(parent, x, y, w, h, title, body, tag, accent) {
  const c = panel(parent, "Feature", x, y, w, h);
  glow(c, w - 40, 20, 220, accent, 0.18, "glow");
  // icon tile
  const t = frame(c, "icon", 24, 24, 44, 44, { r: 12, fill: P(accent, 0.12), stroke: P(accent, 0.4) });
  logoMark(t, 6, 6, 32, accent);
  text(c, title, 24, 88, { size: 19, weight: 500, ls: -1.5, w: w - 48 });
  text(c, body, 24, 120, { size: 14.5, color: K.mut, lh: 22, w: w - 48 });
  mono(c, tag + "  →", 24, h - 40, { size: 12.5, color: accent, weight: 500 });
  return c;
}

// ---- desktop ---------------------------------------------------------------------------------
function desktop(themeName) {
  const W = 1440, H = 3180;
  const f = pageFrame(`Home / Desktop / ${themeName}`, W, H, { gridH: 3180 });
  // hero atmosphere
  glow(f, 720, 330, 1100, K.a1, K.glow, "hero glow"); glow(f, 1080, 260, 760, K.a2, K.glow * 0.9, "hero glow 2");
  nav(f, W, { active: -1 });
  chip(f, "macOS fleet CI · open source · Apache-2.0", 450, 128, { dot: K.a1 });
  text(f, "Commit it. Screenshot it.", 0, 186, { size: 84, weight: 700, ls: -4.5, w: W, align: "CENTER", lh: 90, name: "H1 a" });
  text(f, "Ship it.", 0, 276, { size: 84, weight: 700, ls: -4.5, w: W, align: "CENTER", lh: 90, color: K.a1, name: "H1 b" });
  text(f, "Your Mac is your CI, your screenshot studio and your video studio. Ephemeral runners that scale to your queue, store screenshots in every locale, and launch videos that rebuild from your repo. No cloud bill, no watermark.", 360, 392, { size: 19, color: K.mut, lh: 30, w: 720, align: "CENTER" });
  button(f, "Get started", 500, 520, { primary: true, w: 140, h: 52 });
  button(f, "Why kinhin?", 656, 520, { w: 140, h: 52 });
  button(f, "CLI reference", 812, 520, { w: 140, h: 52 });
  // ring + install terminal
  const cx = 720;
  for (const [d, a] of [[560, 0.05], [440, 0.08], [320, 0.12]]) oval(f, cx - d / 2, 740 - d / 2, d, d, { stroke: P(K.a1, a), sw: 1, name: "orbit" });
  codeBlock(f, 330, 650, 780, [
    ["$ curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash", "#EAEEF6"],
    ["$ kinhin config init && kinhin auth set", "#EAEEF6"],
    ["$ kinhin image prepare && kinhin start", "#EAEEF6"],
    ["✓ fleet online · 4 runners · 2 forges", K.a1],
  ], { title: "up and running in three commands", glow: true, name: "Install terminal" });

  // launch video
  mono(f, "// LAUNCH VIDEO", 120, 960, { size: 12.5, color: K.a1, weight: 500, ls: 8 });
  text(f, "Rebuilt from your repo, every release.", 120, 988, { size: 40, weight: 700, ls: -3, w: 700 });
  const v = panel(f, "Video", 120, 1072, 1200, 640, { r: 20, fill: P(K.code) });
  glow(v, 600, 320, 900, K.a2, 0.25, "vglow");
  const play = oval(v, 1080, 540, 64, 64, { fill: P("#FFFFFF", 0.12), stroke: P("#FFFFFF", 0.4), name: "play" });
  vec(v, "M 0 0 L 18 11 L 0 22 Z", { x: 1105, y: 561, stroke: P("#FFFFFF"), sw: 2 });
  const win = frame(v, "App window", 300, 130, 600, 300, { r: 12, fill: P("#FFFFFF", 0.05), stroke: P("#FFFFFF", 0.14) });
  for (let i = 0; i < 3; i++) oval(win, 14 + i * 16, 14, 10, 10, { fill: P("#FFFFFF", 0.2) });
  [["runner-01", 0.9], ["runner-02", 0.9], ["runner-03", 0.5], ["runner-04", 0.5]].forEach(([n, a], i) => { rect(win, 20, 52 + i * 56, 560, 44, { r: 8, fill: P("#FFFFFF", 0.04), name: "row" }); oval(win, 36, 68 + i * 56, 10, 10, { fill: P(K.a1, a) }); mono(win, n, 60, 66 + i * 56, { size: 13, color: "#C8D0E0" }); mono(win, a > 0.6 ? "running  ·  macOS 15" : "idle", 400, 66 + i * 56, { size: 12.5, color: "#8B93A7" }); });
  const cap = frame(v, "caption", 400, 500, 400, 44, { r: 10, fill: P("#000000", 0.6) }); text(cap, "Commit it. Screenshot it. Ship it.", 0, 11, { size: 17, weight: 500, color: "#FFFFFF", w: 400, align: "CENTER" });
  mono(v, "launch.mp4  ·  1:12  ·  captions · narration · vertical cut", 24, 600, { size: 12.5, color: "#8B93A7" });
  const tabs = frame(v, "tabs", 940, 20, 240, 34, { r: 8, fill: P("#FFFFFF", 0.06), stroke: BORDER() });
  mono(tabs, "launch", 18, 9, { size: 12.5, color: K.tx, weight: 500 }); mono(tabs, "beta-4", 120, 9, { size: 12.5, color: "#8B93A7" });

  // fleet diagram
  mono(f, "// HOW IT RUNS", 120, 1780, { size: 12.5, color: K.a1, weight: 500, ls: 8 });
  text(f, "Parallel jobs, not a queue.", 120, 1808, { size: 40, weight: 700, ls: -3, w: 700 });
  const fd = panel(f, "Fleet diagram", 120, 1892, 1200, 340, { r: 20 });
  glow(fd, 600, 170, 700, K.a1, 0.1, "g");
  const nodes = [["forges", ["GitHub", "GitLab", "Gitea", "Forgejo"], 70], ["kinhin", ["ephemeral", "runners", "autoscale"], 520], ["jobs", ["macOS · Tart", "Linux · container", "Docker · host"], 930]];
  nodes.forEach(([title, items, x], i) => {
    const bx = x, by = 40;
    const b = frame(fd, "node " + title, bx, by, 220, 260, { r: 14, fill: P(K.code), stroke: i === 1 ? P(K.a1, 0.6) : BORDER() });
    mono(b, title.toUpperCase(), 20, 18, { size: 12, color: i === 1 ? K.a1 : K.dim, weight: 500, ls: 10 });
    items.forEach((s, j) => { oval(b, 20, 62 + j * 50, 8, 8, { fill: P(i === 1 ? K.a1 : K.a1), name: "dot" }); mono(b, s, 40, 56 + j * 50, { size: 14, color: K.tx }); });
  });
  rect(fd, 290, 170, 230, 2, { fill: P(K.a1, 0.8), name: "wire" });
  rect(fd, 740, 170, 190, 2, { fill: P(K.a1, 0.8), name: "wire" });
  for (const x of [380, 840]) oval(fd, x, 165, 10, 10, { fill: P(K.a1), name: "packet" });

  // features
  mono(f, "// WHAT YOU GET", 120, 2300, { size: 12.5, color: K.a1, weight: 500, ls: 8 });
  const feats = [
    ["Parallel jobs, not a queue", "A fleet of ephemeral runners scales to your queue, so jobs run side by side.", "Why kinhin", K.a1],
    ["Clean every time", "Every job gets a fresh VM or container, deleted when the job ends. Nothing leaks between jobs.", "Security", K.a1],
    ["Multi-forge, multi-runtime", "GitHub, Gitea, Forgejo and GitLab served from one pool, on Tart, apple/container, Docker or host mode.", "Runtimes & routing", K.a2],
    ["Store screenshots", "One fastlane lane captures localized App Store and Play screenshots in CI.", "Store screenshots", K.a1],
    ["Launch videos from a config", "Write the story in YAML. Get narration, captions, music and a vertical cut on every release.", "Add videos", K.a2],
    ["Menu bar or headless", "The same engine as a macOS app or a LaunchAgent daemon, with one config and one fleet.", "Install", K.a1],
  ];
  feats.forEach((fe, i) => featureCard(f, 120 + (i % 3) * 408, 2336 + Math.floor(i / 3) * 252, 384, 236, ...fe));

  // human / agent split
  const sp = panel(f, "For agents", 120, 2860, 1200, 170, { r: 20 });
  glow(sp, 1000, 85, 520, K.a2, 0.22, "g");
  mono(sp, "// FOR AGENTS", 40, 34, { size: 12.5, color: K.a2, weight: 500, ls: 8 });
  text(sp, "Every page is also markdown.", 40, 62, { size: 30, weight: 700, ls: -2 });
  text(sp, "Ask for any URL with Accept: text/markdown, append .md, or start at llms.txt. Agent skills ship in the repo.", 40, 108, { size: 15, color: K.mut, w: 600 });
  codeBlock(sp, 720, 36, 440, [["$ curl -H 'Accept: text/markdown' \\", "#EAEEF6"], ["    https://kinhin.dev/guide/quick-start", "#EAEEF6"], ["# Quick start  …", K.a1]], { name: "curl" });
  // footer
  const ft = frame(f, "Footer", 0, 3070, W, 110, {});
  line(ft, 0, 0, W, 1, BORDER(), "border");
  logoMark(ft, 114, 34, 32); text(ft, "kinhin", 150, 38, { size: 17, weight: 700 });
  mono(ft, "Apache-2.0 · Support · Used by · SupDesk", 120, 76, { size: 12.5, color: K.dim });
  mono(ft, "Your Mac is your CI.", 1000, 40, { size: 13, color: K.mut, w: 320, align: "RIGHT" });
  return f;
}

// ---- mobile ----------------------------------------------------------------------------------
function mobile(themeName) {
  const W = 390, H = 2480;
  const f = pageFrame(`Home / Mobile / ${themeName}`, W, H, { gridH: 760 });
  glow(f, 195, 250, 560, K.a1, K.glow, "hero glow"); glow(f, 330, 200, 360, K.a2, K.glow * 0.9, "hero glow 2");
  nav(f, W);
  chip(f, "macOS fleet CI · open source", 20, 100, { dot: K.a1 });
  text(f, "Commit it.\nScreenshot it.", 20, 150, { size: 52, weight: 700, ls: -4, w: 350, lh: 56 });
  text(f, "Ship it.", 20, 262, { size: 52, weight: 700, ls: -4, w: 350, lh: 56, color: K.a1 });
  text(f, "Your Mac is your CI, your screenshot studio and your video studio. No cloud bill, no watermark.", 20, 344, { size: 16, color: K.mut, lh: 25, w: 350 });
  button(f, "Get started", 20, 440, { primary: true, w: 350, h: 50 });
  button(f, "Why kinhin?", 20, 502, { w: 350, h: 50 });
  codeBlock(f, 20, 580, 350, [["$ curl -fsSL …/install.sh | bash", "#EAEEF6"], ["$ kinhin config init", "#EAEEF6"], ["$ kinhin start", "#EAEEF6"], ["✓ fleet online", K.a1]], { title: "3 commands", glow: true });
  mono(f, "// WHAT YOU GET", 20, 800, { size: 12, color: K.a1, weight: 500, ls: 8 });
  const feats = [["Parallel jobs, not a queue", "A fleet of ephemeral runners scales to your queue.", "Why kinhin", K.a1], ["Clean every time", "Fresh VM or container per job, deleted when it ends.", "Security", K.a1], ["Multi-forge, multi-runtime", "GitHub, Gitea, Forgejo and GitLab from one pool.", "Runtimes", K.a2], ["Store screenshots", "Localized App Store and Play screenshots in CI.", "Screenshots", K.a1], ["Launch videos from a config", "Narration, captions, music and a vertical cut.", "Add videos", K.a2]];
  feats.forEach((fe, i) => featureCard(f, 20, 836 + i * 232, 350, 216, fe[0], fe[1], fe[2], fe[3]));
  const sp = panel(f, "For agents", 20, 2012, 350, 300, { r: 18 }); glow(sp, 300, 40, 300, K.a2, 0.22, "g");
  mono(sp, "// FOR AGENTS", 20, 22, { size: 12, color: K.a2, weight: 500, ls: 8 });
  text(sp, "Every page is also markdown.", 20, 48, { size: 24, weight: 700, ls: -1.5, w: 310 });
  codeBlock(sp, 16, 124, 318, [["$ curl -H 'Accept: \\", "#EAEEF6"], ["  text/markdown' kinhin.dev/…", "#EAEEF6"]], { name: "curl" });
  const ft = frame(f, "Footer", 0, 2370, W, 110, {}); line(ft, 0, 0, W, 1, BORDER(), "border");
  logoMark(ft, 14, 28, 32); text(ft, "kinhin", 50, 32, { size: 17, weight: 700 });
  mono(ft, "Apache-2.0 · Support · Used by", 20, 72, { size: 12, color: K.dim });
  return f;
}

