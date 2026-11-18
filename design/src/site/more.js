// Blog index, CLI reference, search palette, 404 and version banner. Desktop 1440.
function heading(f, kicker, title, sub, y = 120) {
  mono(f, kicker, 120, y, { size: 12.5, color: K.a1, weight: 500, ls: 8 });
  text(f, title, 120, y + 28, { size: 56, weight: 700, ls: -4, w: 900 });
  if (sub) text(f, sub, 120, y + 104, { size: 18, color: K.mut, lh: 28, w: 640 });
}
function blog(themeName) {
  const W = 1440, H = 1180; const f = pageFrame(`Blog / Desktop / ${themeName}`, W, H, { gridH: H });
  nav(f, W, { active: 1 });
  heading(f, "// BLOG", "Release notes and field notes.", "What shipped in each beta, and what we learned running a Mac fleet.");
  const posts = [["beta-6", "Beta 6", "Faster image prepare, per-project toolchains and a calmer menu bar.", "2026-10-28"], ["beta-5", "Beta 5", "Buildkite groundwork, runner routing by workflow, and a new doctor.", "2026-10-02"], ["beta-4", "Beta 4", "Launch videos from a YAML story, with narration, captions and music.", "2026-09-11"], ["beta-3", "Beta 3", "Store screenshots in every locale from one fastlane lane.", "2026-08-19"], ["beta-2", "Beta 2", "Gitea, Forgejo and GitLab served from the same pool.", "2026-07-30"], ["beta", "Introducing kinhin beta", "Your Mac is your CI. Why we built it and what works today.", "2026-07-01"]];
  posts.forEach(([tag, t, d, date], i) => {
    const x = 120 + (i % 2) * 612, y = 380 + Math.floor(i / 2) * 250;
    const c = panel(f, "Post", x, y, 588, 226, { r: 16 });
    mono(c, tag.toUpperCase() + "  ·  " + date, 28, 28, { size: 12, color: K.a1, weight: 500, ls: 4 });
    text(c, t, 28, 62, { size: 28, weight: 700, ls: -2, w: 520 });
    text(c, d, 28, 108, { size: 15.5, color: K.mut, lh: 24, w: 520 });
    mono(c, "Read post  →", 28, 184, { size: 13, color: K.a1, weight: 500 });
  });
  return f;
}
function cli(themeName) {
  const W = 1440, H = 1180; const f = pageFrame(`CLI / Desktop / ${themeName}`, W, H, { gridH: H });
  nav(f, W, { active: -1 });
  heading(f, "// REFERENCE", "CLI commands", "Everything the kinhin command does, generated from the binary's own help.");
  codeBlock(f, 120, 380, 800, [
    ["kinhin — autoscaling CI runners on your Mac.", "#EAEEF6"], ["", ""], ["USAGE:", K.a1],
    ["    kinhin                                  Setup status and the next step", "#C8D0E0"],
    ["    kinhin <command> [options]", "#C8D0E0"], ["", ""], ["SETUP:", K.a1],
    ["    config init                             Write a starter config file", "#C8D0E0"],
    ["    config validate [FILE]                  Check the config without starting", "#C8D0E0"],
    ["    auth set                                Store (or replace) a token in the Keychain", "#C8D0E0"],
    ["    doctor                                  Check prerequisites and the computed capacity", "#C8D0E0"],
    ["    setup repair tart                       Install tart for macOS VMs", "#C8D0E0"], ["", ""], ["IMAGES AND TOOLCHAINS:", K.a1],
    ["    image prepare                           Build the runner base image (slow, once)", "#C8D0E0"],
    ["    toolchains detect [path]                Scan a checkout for the toolchains it needs", "#C8D0E0"],
  ], { title: "kinhin --help", name: "Help" });
  const t = panel(f, "Exit codes", 960, 380, 360, 360, { r: 16 });
  mono(t, "EXIT CODES", 24, 24, { size: 12, color: K.dim, weight: 500, ls: 8 });
  [["0", "ok"], ["1", "failed"], ["2", "usage"], ["3", "not configured"], ["4", "daemon unreachable"]].forEach(([c, d], i) => { mono(t, c, 24, 64 + i * 52, { size: 20, color: K.a1, weight: 500 }); text(t, d, 70, 66 + i * 52, { size: 15.5, color: K.tx }); line(t, 24, 100 + i * 52, 312, 1, BORDER(), "row"); });
  return f;
}
function search(themeName) {
  const f = docsBackdrop(`Search / Desktop / ${themeName}`);
  rect(f, 0, 0, 1440, 1000, { fill: P("#000000", 0.62), name: "scrim" });
  const m = frame(f, "Palette", 410, 160, 620, 560, { r: 16, fill: P(K.bg2), stroke: P(K.a1, 0.5), fx: [shadow("#000000", 0.6, 80, 20)] });
  text(m, "install runner", 52, 22, { size: 18 }); mono(m, "⌕", 20, 24, { size: 16, color: K.a1 }); rect(m, 300, 24, 1, 20, { fill: P(K.a1), name: "caret" });
  mono(m, "ESC", 560, 26, { size: 11.5, color: K.dim }); line(m, 0, 68, 620, 1, BORDER(), "sep");
  mono(m, "GUIDE", 24, 90, { size: 11.5, color: K.dim, weight: 500, ls: 8 });
  [["Install", "Install kinhin and a Linux runtime", true], ["Quick start", "Requirements, install, pick your forge", false], ["Runtimes & routing", "Choose Tart, container or Docker per repo", false]].forEach(([t, d, on], i) => {
    const y = 116 + i * 72; if (on) rect(m, 12, y, 596, 64, { r: 10, fill: P(K.a1, 0.12), stroke: P(K.a1, 0.4), name: "hit" });
    text(m, t, 30, y + 10, { size: 16, weight: 500, color: on ? K.a1 : K.tx }); text(m, d, 30, y + 34, { size: 13.5, color: K.mut });
  });
  mono(m, "SEARCH PAGES", 24, 346, { size: 11.5, color: K.dim, weight: 500, ls: 8 });
  [["How to run GitHub Actions on a self-hosted Mac", "/how-to-run-github-actions-on-a-self-hosted-mac"], ["How many macOS VMs can run at once?", "/how-many-macos-vms-can-run-at-once"]].forEach(([t, d], i) => { const y = 372 + i * 72; text(m, t, 30, y + 10, { size: 16, weight: 500 }); mono(m, d, 30, y + 36, { size: 12, color: K.dim }); });
  line(m, 0, 520, 620, 1, BORDER(), "sep"); mono(m, "↑↓ navigate   ↵ open   ⌘↵ copy as markdown", 24, 534, { size: 11.5, color: K.dim });
  return f;
}
function docsBackdrop(name) {
  const f = pageFrame(name, 1440, 1000, { gridH: 1000 }); nav(f, 1440, { active: 2 });
  line(f, 300, 68, 1, 932, BORDER(), "edge"); text(f, "Install", 360, 130, { size: 52, weight: 700, ls: -3.5 });
  text(f, "Install kinhin and a Linux runtime, then prepare the base image.", 360, 210, { size: 18, color: K.mut, w: 640 });
  return f;
}
function notFound(themeName) {
  const W = 1440, H = 820; const f = pageFrame(`404 / Desktop / ${themeName}`, W, H, { gridH: H });
  nav(f, W);
  for (const [d, a] of [[520, 0.08], [380, 0.14], [240, 0.25]]) oval(f, 720 - d / 2, 330 - d / 2, d, d, { stroke: P(K.a1, a), sw: 1.5, name: "orbit" });
  text(f, "404", 0, 262, { size: 120, weight: 700, ls: -6, w: W, align: "CENTER", color: K.a1 });
  text(f, "This runner went offline.", 0, 470, { size: 34, weight: 700, ls: -2, w: W, align: "CENTER" });
  text(f, "The page you asked for is gone, or never existed.", 0, 520, { size: 17, color: K.mut, w: W, align: "CENTER" });
  button(f, "Back to docs", 560, 580, { primary: true, w: 150, h: 48 }); button(f, "Search  ⌘K", 726, 580, { w: 150, h: 48 });
  return f;
}
function version(themeName) {
  const f = pageFrame(`Version banner / Desktop / ${themeName}`, 1440, 760, { gridH: 760 });
  const b = frame(f, "Version banner", 0, 0, 1440, 40, { fill: P(K.a1, 0.16) }); line(b, 0, 39, 1440, 1, P(K.a1, 0.4), "border");
  mono(b, "You are reading the docs for v0.1.0-beta.3.  Latest (main) →", 0, 12, { size: 13, color: K.a1, weight: 500, w: 1440, align: "CENTER" });
  const n = nav(f, 1440, { active: 2 }); n.y = 40;
  const pk = frame(f, "Version picker", 1090, 112, 230, 188, { r: 12, fill: P(K.bg2), stroke: BORDER(), fx: [shadow("#000000", 0.5, 40, 12)] });
  [["Latest (main)", false], ["v0.1.0-beta.6", false], ["v0.1.0-beta.5", false], ["v0.1.0-beta.4", false], ["v0.1.0-beta.3", true]].forEach(([s, on], i) => { if (on) rect(pk, 6, 8 + i * 34, 218, 32, { r: 8, fill: P(K.a1, 0.14), name: "on" }); mono(pk, s, 18, 16 + i * 34, { size: 13, color: on ? K.a1 : K.tx, weight: on ? 500 : 400 }); });
  mono(f, "Version", 1090, 90, { size: 11.5, color: K.dim, weight: 500, ls: 8 });
  text(f, "Quick start", 120, 160, { size: 52, weight: 700, ls: -3.5 });
  return f;
}
