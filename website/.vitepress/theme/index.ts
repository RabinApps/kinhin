import { h, onBeforeUnmount, onMounted, onUpdated, nextTick } from "vue";
import DefaultTheme from "vitepress/theme";
import type { Theme } from "vitepress";
import "./version-banner.css";

function addDiagramExpandButtons(): void {
  const diagrams = document.querySelectorAll<HTMLElement>(".vp-doc pre.mermaid[data-processed]");
  for (const diagram of diagrams) {
    const parent = diagram.parentElement;
    if (!parent || parent.classList.contains("diagram-frame")) continue;

    const frame = document.createElement("div");
    frame.className = "diagram-frame";
    parent.insertBefore(frame, diagram);
    frame.append(diagram);

    const expand = document.createElement("button");
    expand.className = "diagram-expand-button";
    expand.type = "button";
    expand.textContent = "Expand";
    expand.setAttribute("aria-label", "Expand diagram to full screen");
    expand.addEventListener("click", () => openDiagramFullscreen(diagram, expand));
    frame.append(expand);
  }
}

const MIN_ZOOM = 0.5;
const MAX_ZOOM = 4;
const ZOOM_STEP = 0.25;

function zoomButton(label: string, ariaLabel: string, onClick: () => void): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "diagram-zoom-button";
  button.textContent = label;
  button.setAttribute("aria-label", ariaLabel);
  button.addEventListener("click", onClick);
  return button;
}

function openDiagramFullscreen(diagram: HTMLElement, expandButton: HTMLButtonElement): void {
  const placeholder = document.createComment("diagram position");
  diagram.before(placeholder);

  const dialog = document.createElement("dialog");
  dialog.className = "diagram-fullscreen";
  dialog.setAttribute("aria-label", "Expanded architecture diagram");

  const toolbar = document.createElement("div");
  toolbar.className = "diagram-fullscreen-toolbar";
  const title = document.createElement("span");
  title.textContent = "Architecture diagram";
  const hint = document.createElement("span");
  hint.className = "diagram-zoom-hint";
  hint.textContent = " drag to pan · + / − keys or Ctrl+scroll to zoom, 0 to reset";
  title.append(hint);

  const content = document.createElement("div");
  content.className = "diagram-fullscreen-content";
  content.append(diagram);

  // Zoom state: the diagram box is sized explicitly (container × zoom) rather
  // than with CSS `zoom` alone. The fullscreen rules give the pre definite
  // `width/height: 100%`, and a percentage-sized box does not grow under CSS
  // zoom — so the scroll container never overflows and can't scroll. Explicit
  // pixel sizes make the content area overflow in both axes and scroll.
  let zoom = 1;
  const zoomLevel = document.createElement("span");
  zoomLevel.className = "diagram-zoom-level";
  zoomLevel.setAttribute("aria-live", "polite");
  // Mermaid gives the svg an inline max-width; remember it so close() can
  // restore the inline view exactly as it was.
  const svg = diagram.querySelector("svg");
  const svgOriginalStyle = svg?.getAttribute("style") ?? null;
  diagram.style.boxSizing = "border-box"; // width/height include the 24px padding
  const applyZoom = () => {
    diagram.style.width = `${Math.round(content.clientWidth * zoom)}px`;
    diagram.style.height = `${Math.round(content.clientHeight * zoom)}px`;
    // The svg is sized 100% of the pre; drop the viewport-based caps so the
    // drawing scales with the box instead of being letterboxed at 100%.
    if (svg) {
      svg.style.maxWidth = "none";
      svg.style.maxHeight = "none";
    }
    zoomLevel.textContent = `${Math.round(zoom * 100)}%`;
    // Drag-to-pan only makes sense when the diagram actually overflows.
    if (
      content.scrollWidth > content.clientWidth ||
      content.scrollHeight > content.clientHeight
    ) content.setAttribute("data-pannable", "");
    else content.removeAttribute("data-pannable");
  };
  const stepZoom = (direction: number) => {
    zoom = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, zoom + direction * ZOOM_STEP));
    applyZoom();
  };
  const resetZoom = () => {
    zoom = 1;
    applyZoom();
  };

  const zoomControls = document.createElement("div");
  zoomControls.className = "diagram-zoom-controls";
  zoomControls.append(
    zoomButton("−", "Zoom out", () => stepZoom(-1)),
    zoomLevel,
    zoomButton("+", "Zoom in", () => stepZoom(1)),
    zoomButton("Reset", "Reset zoom to 100%", resetZoom),
  );

  const close = document.createElement("button");
  close.type = "button";
  close.className = "diagram-close-button";
  close.textContent = "Close";
  close.setAttribute("aria-label", "Close expanded diagram");
  close.addEventListener("click", () => dialog.close());
  toolbar.append(title, zoomControls, close);

  // Drag-to-pan with the mouse (touch keeps native scrolling). The handlers
  // live on `content`, which is discarded with the dialog on close.
  let pan: { pointerId: number; x: number; y: number; left: number; top: number } | null = null;
  content.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || event.pointerType === "touch") return;
    if (!content.hasAttribute("data-pannable")) return;
    // When the diagram overflows it covers the whole viewport, so the only
    // pointerdowns targeting the scroll container itself come from its native
    // scrollbars — leave those to the scrollbar.
    if (event.target === content) return;
    pan = {
      pointerId: event.pointerId,
      x: event.clientX,
      y: event.clientY,
      left: content.scrollLeft,
      top: content.scrollTop,
    };
    content.classList.add("is-panning");
    // Best-effort: keeps move events flowing when the pointer leaves the
    // dialog mid-drag (throws for synthetic/test pointers).
    try { content.setPointerCapture(event.pointerId); } catch {}
    // Also stops the drag from selecting the diagram's labels.
    event.preventDefault();
  });
  content.addEventListener("pointermove", (event) => {
    if (!pan || event.pointerId !== pan.pointerId) return;
    content.scrollLeft = pan.left - (event.clientX - pan.x);
    content.scrollTop = pan.top - (event.clientY - pan.y);
  });
  const endPan = (event: PointerEvent) => {
    if (!pan || event.pointerId !== pan.pointerId) return;
    pan = null;
    content.classList.remove("is-panning");
    try { content.releasePointerCapture(event.pointerId); } catch {}
  };
  content.addEventListener("pointerup", endPan);
  content.addEventListener("pointercancel", endPan);

  // Ctrl/Cmd + wheel zooms, like a map: plain wheel still scrolls the content.
  content.addEventListener(
    "wheel",
    (event) => {
      if (!event.ctrlKey && !event.metaKey) return;
      event.preventDefault();
      stepZoom(event.deltaY < 0 ? 1 : -1);
    },
    { passive: false },
  );
  dialog.append(toolbar, content);
  document.body.append(dialog);

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key === "+" || event.key === "=") {
      event.preventDefault();
      stepZoom(1);
    } else if (event.key === "-" || event.key === "_") {
      event.preventDefault();
      stepZoom(-1);
    } else if (event.key === "0") {
      event.preventDefault();
      resetZoom();
    }
  };
  document.addEventListener("keydown", onKeyDown);
  // Re-fit on resize so a rotated/resized window keeps the zoom factor applied
  // to the current container size.
  window.addEventListener("resize", applyZoom);

  dialog.addEventListener("click", (event) => {
    if (event.target === dialog) dialog.close();
  });
  dialog.addEventListener("close", () => {
    document.removeEventListener("keydown", onKeyDown);
    window.removeEventListener("resize", applyZoom);
    diagram.style.removeProperty("width");
    diagram.style.removeProperty("height");
    diagram.style.removeProperty("box-sizing");
    diagram.style.removeProperty("zoom");
    if (svg) {
      if (svgOriginalStyle === null) svg.removeAttribute("style");
      else svg.setAttribute("style", svgOriginalStyle);
    }
    placeholder.replaceWith(diagram);
    dialog.remove();
    expandButton.focus();
  }, { once: true });

  // showModal first: the dialog is display:none until open, so clientWidth/
  // Height would read 0 before it.
  dialog.showModal();
  applyZoom();
  close.focus();
}

async function renderMermaidDiagrams(): Promise<void> {
  const theme = document.documentElement.classList.contains("dark") ? "dark" : "default";
  const diagrams = Array.from(document.querySelectorAll<HTMLElement>("pre.mermaid"));
  const outdated = diagrams.filter((diagram) => diagram.dataset.mermaidTheme !== theme);
  if (outdated.length > 0) {
    const { default: mermaid } = await import("mermaid");
    for (const diagram of outdated) {
      if (diagram.dataset.mermaidSource === undefined) {
        diagram.dataset.mermaidSource = diagram.textContent ?? "";
      } else {
        diagram.textContent = diagram.dataset.mermaidSource;
      }
      diagram.removeAttribute("data-processed");
    }
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme,
    });
    await mermaid.run({ nodes: outdated });
    for (const diagram of outdated) diagram.dataset.mermaidTheme = theme;
  }
  addDiagramExpandButtons();
}

declare const __DOCS_VERSION__: string;
declare const __DOCS_BETA__: boolean;

// Snapshot builds (DOCS_VERSION set) show a notice linking to the latest docs.
export default {
  extends: DefaultTheme,
  Layout: {
    setup() {
      let appearanceObserver: MutationObserver | undefined;
      let renderQueue = Promise.resolve();
      const renderAfterUpdate = () => {
        void nextTick(() => {
          renderQueue = renderQueue.then(renderMermaidDiagrams).catch((error: unknown) => {
            console.error("Could not render architecture diagrams:", error);
          });
        });
      };
      onMounted(() => {
        appearanceObserver = new MutationObserver(renderAfterUpdate);
        appearanceObserver.observe(document.documentElement, {
          attributes: true,
          attributeFilter: ["class"],
        });
        renderAfterUpdate();
      });
      onBeforeUnmount(() => appearanceObserver?.disconnect());
      onUpdated(renderAfterUpdate);
      return () =>
        h(DefaultTheme.Layout, null, {
          "nav-bar-title-after": () =>
            __DOCS_BETA__
              ? h("a", { class: "beta-badge", href: "/guide/beta-roadmap", target: "_self" }, "beta")
              : null,
          "layout-top": () =>
            __DOCS_VERSION__
              ? h("div", { class: "version-banner" }, [
                  `You are reading the docs for ${__DOCS_VERSION__}. `,
                  h("a", { href: "/", target: "_self" }, "View the latest docs"),
                  ".",
                ])
              : null,
        });
    },
  },
} satisfies Theme;
