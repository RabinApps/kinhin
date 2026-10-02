import { h } from "vue";
import DefaultTheme from "vitepress/theme";
import type { Theme } from "vitepress";
import "./version-banner.css";

declare const __DOCS_VERSION__: string;
declare const __DOCS_BETA__: boolean;

// Snapshot builds (DOCS_VERSION set) show a notice linking to the latest docs.
export default {
  extends: DefaultTheme,
  Layout: () =>
    h(DefaultTheme.Layout, null, {
      "nav-bar-title-after": () =>
        __DOCS_BETA__ ? h("a", { class: "beta-badge", href: "/guide/beta-roadmap", target: "_self" }, "beta") : null,
      "layout-top": () =>
        __DOCS_VERSION__
          ? h("div", { class: "version-banner" }, [
              `You are reading the docs for ${__DOCS_VERSION__}. `,
              h("a", { href: "/", target: "_self" }, "View the latest docs"),
              ".",
            ])
          : null,
    }),
} satisfies Theme;
