#!/usr/bin/env node
// Builds design/kinhin-site.fig and design/exports/site/*.png headlessly with the OpenPencil CLI (npm i -g @open-pencil/cli).
// The CLI only bundles Inter and cannot read system fonts. Geist (`Geist`) and Geist Mono (`GeistMono`, one word) must be
// added to its bundled fonts: copy the static .ttf files from the `geist` npm package into
// <cli>/node_modules/@open-pencil/core/assets/ and add `"Geist|Regular": "/Geist-Regular.ttf"` style entries (Regular, Medium,
// Bold; GeistMono likewise) to BUNDLED_FONTS in <cli>/node_modules/@open-pencil/core/dist/text/fonts.js.
//   node design/src/site/build.mjs [page ...]      (no args = every page)
// Each page script defines frame builders; PAGES below says which to call, with which theme.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

const here = dirname(fileURLToPath(import.meta.url));
const design = resolve(here, "../..");
const FIG = join(design, "kinhin-site.fig");
const OUT = join(design, "exports/site");
const lib = readFileSync(join(here, "lib.js"), "utf8");

// [file, call expression, theme, frame name, width]
const PAGES = [
  ["home.js", 'desktop("dark")', "dark", "Home / Desktop / dark", 1440],
  ["home.js", 'mobile("dark")', "dark", "Home / Mobile / dark", 390],
  ["home.js", 'desktop("light")', "light", "Home / Desktop / light", 1440],
  ["docs.js", 'desktop("dark")', "dark", "Docs / Desktop / dark", 1440],
  ["docs.js", 'mobile("dark")', "dark", "Docs / Mobile / dark", 390],
  ["docs.js", 'desktop("light")', "light", "Docs / Desktop / light", 1440],
  ["more.js", 'blog("dark")', "dark", "Blog / Desktop / dark", 1440],
  ["more.js", 'cli("dark")', "dark", "CLI / Desktop / dark", 1440],
  ["more.js", 'search("dark")', "dark", "Search / Desktop / dark", 1440],
  ["more.js", 'notFound("dark")', "dark", "404 / Desktop / dark", 1440],
  ["more.js", 'version("dark")', "dark", "Version banner / Desktop / dark", 1440],
  ["tokens.js", 'sheet("dark")', "dark", "Tokens and components", 1440],
];

const filter = process.argv.slice(2);
const sh = (args, input) => execFileSync("openpencil", args, { input, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"], maxBuffer: 1 << 26 });
const only = (name) => !filter.length || filter.some((f) => name.toLowerCase().startsWith(f.toLowerCase()));

const tmp = mkdtempSync(join(tmpdir(), "kinhin-site-"));
if (!filter.length || !existsSync(FIG)) {
  writeFileSync(join(tmp, "seed.html"), '<div style="width:10px;height:10px"></div>');
  sh(["import", join(tmp, "seed.html"), "-o", FIG]);
  sh(["eval", FIG, "-w", "--stdin"], "for (const n of [...figma.currentPage.children]) n.remove(); return 'seeded';");
}
let x = 0;
for (const [file, call, theme, name, w] of PAGES) {
  const at = x; x += w + 160;
  if (!only(name)) continue;
  if (!existsSync(join(here, file))) { console.log("skip (missing)", file); continue; }
  // replace an existing frame of the same name so a single page can be rebuilt
  const code = `${lib}\nawait loadFonts();\nfor (const n of [...figma.currentPage.children]) if (n.name === ${JSON.stringify(name)}) n.remove();\nsetTheme(${JSON.stringify(theme)});\n${readFileSync(join(here, file), "utf8")}\nconst __f = ${call}; __f.name = ${JSON.stringify(name)}; __f.x = ${at}; __f.y = 0; return __f.name;`;
  try { sh(["eval", FIG, "-w", "--stdin"], code); console.log("built", name); }
  catch (e) { console.error("FAILED", name, (e.stderr || e.message).split("\n").filter((l) => !/unifont|fetch|cause|ENOTFOUND|hostname|at async|Could not/.test(l)).join("\n")); process.exitCode = 1; }
}
mkdirSync(OUT, { recursive: true });
const tree = sh(["tree", FIG]);
for (const [, , , name] of PAGES) {
  if (!only(name)) continue;
  const m = tree.split("\n").find((l) => l.includes(`"${name}"`)); const id = m && m.match(/\((\d+:\d+)\)/)?.[1];
  if (!id) continue;
  const file = join(OUT, name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") + ".png");
  sh(["export", FIG, "-f", "png", "-s", "1", "--node", id, "-o", file]); console.log("exported", file);
}
