// Build wrapper for a release snapshot (/<tag>/), installed by .github/workflows/docs.yml over the
// tag's own .vitepress/config.ts, which is renamed config.base.ts first. The tag itself is never
// changed: this only adjusts how its frozen docs are built.
//
// - Links to repository files point at the tag, not main: an old version's docs describe the code
//   as it was at that release, and the file on main may have moved, changed or gone.
// - Dead links do not fail the build. A snapshot cannot be fixed after the fact (the tag is
//   protected), so a link that was broken at release time stays visible instead of blocking the
//   deploy of every later version.
import base from "./config.base";

const tag = process.env.DOCS_VERSION;
if (!tag) throw new Error("snapshot.config.ts needs DOCS_VERSION=<tag>");

const repoFiles = /^https:\/\/github\.com\/RabinApps\/kinhin\/(blob|tree|raw)\/(main|develop)\//;

const baseMarkdownConfig = base.markdown?.config;

export default {
  ...base,
  ignoreDeadLinks: true,
  markdown: {
    ...base.markdown,
    config: (md: any) => {
      baseMarkdownConfig?.(md);
      md.core.ruler.push("kinhin-pin-repo-links-to-tag", (state: any) => {
        for (const block of state.tokens) {
          for (const token of block.children ?? []) {
            if (token.type !== "link_open") continue;
            const href = token.attrGet("href");
            if (href && repoFiles.test(href)) {
              token.attrSet("href", href.replace(repoFiles, `https://github.com/RabinApps/kinhin/$1/${tag}/`));
            }
          }
        }
      });
    },
  },
};
