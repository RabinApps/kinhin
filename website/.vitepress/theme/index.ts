import { h, onBeforeUnmount, onMounted, onUpdated, nextTick } from "vue";
import DefaultTheme from "vitepress/theme";
import type { Theme } from "vitepress";
import "./version-banner.css";

function addDiagramExpandButtons(): void {
  const diagrams = document.querySelectorAll<HTMLElement>(
    ".vp-doc pre.mermaid[data-processed]",
  );
  for (const diagram of diagrams) {
    const parent = diagram.parentElement;
    if (!parent || parent.classList.contains("diagram-frame")) continue;

    const frame = document.createElement("div");
    frame.className = "diagram-frame";
    parent.insertBefore(frame, diagram);
    frame.append(diagram);
    // Pinch zooms the inline diagram inside its scrollable frame; one finger
    // keeps native scrolling. The expanded dialog parks `style.zoom` while it
    // is open and restores it on close.
    attachPinchZoom(
      frame,
      () => inlineZoomLevel(diagram),
      (zoom, midX, midY) =>
        anchorZoom(frame, diagram, midX, midY, () => {
          diagram.style.zoom = String(zoom);
        }),
    );

    const expand = document.createElement("button");
    expand.className = "diagram-expand-button";
    expand.type = "button";
    expand.textContent = "Expand";
    expand.setAttribute("aria-label", "Expand diagram to full screen");
    expand.addEventListener("click", () =>
      openDiagramFullscreen(diagram, expand),
    );
    frame.append(expand);
  }
}

const MIN_ZOOM = 0.5;
const MAX_ZOOM = 4;
const ZOOM_STEP = 0.25;

function clampZoom(value: number): number {
  return Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, value));
}

// Resize `box` while pinning the point at (clientX, clientY) — the user's
// fingers — to the same screen position: remember where that point sits inside
// the box, run `resize`, then scroll `scroller` back underneath it.
function anchorZoom(
  scroller: HTMLElement,
  box: HTMLElement,
  clientX: number,
  clientY: number,
  resize: () => void,
): void {
  const before = box.getBoundingClientRect();
  const relX = before.width > 0 ? (clientX - before.left) / before.width : 0.5;
  const relY = before.height > 0 ? (clientY - before.top) / before.height : 0.5;
  resize();
  const after = box.getBoundingClientRect();
  scroller.scrollLeft += after.left + relX * after.width - clientX;
  scroller.scrollTop += after.top + relY * after.height - clientY;
}

// The inline diagram keeps its zoom in `style.zoom`: CSS zoom scales the whole
// box — min-width, padding and the svg's max-width caps included — so the
// frame simply scrolls around the enlarged diagram.
function inlineZoomLevel(diagram: HTMLElement): number {
  return Number.parseFloat(diagram.style.zoom) || 1;
}

// Two-finger pinch for `container`: `getZoom()` snapshots the level when the
// second finger lands and `applyZoom(level, midX, midY)` runs for each move.
// One finger is left to native scrolling; only two-finger moves are claimed,
// through preventDefault plus `touch-action: pan-x pan-y` in the stylesheet.
function attachPinchZoom(
  container: HTMLElement,
  getZoom: () => number,
  applyZoom: (zoom: number, midX: number, midY: number) => void,
): void {
  let pinch: { distance: number; zoom: number } | null = null;
  const distance = (touches: TouchList): number =>
    Math.hypot(
      touches[0].clientX - touches[1].clientX,
      touches[0].clientY - touches[1].clientY,
    );
  container.addEventListener("touchstart", (event) => {
    if (event.touches.length !== 2) return;
    pinch = { distance: distance(event.touches), zoom: getZoom() };
  });
  container.addEventListener(
    "touchmove",
    (event) => {
      if (event.touches.length !== 2 || !pinch || pinch.distance === 0) return;
      event.preventDefault();
      const midX = (event.touches[0].clientX + event.touches[1].clientX) / 2;
      const midY = (event.touches[0].clientY + event.touches[1].clientY) / 2;
      applyZoom(
        clampZoom(pinch.zoom * (distance(event.touches) / pinch.distance)),
        midX,
        midY,
      );
    },
    { passive: false },
  );
  const end = (event: TouchEvent) => {
    if (event.touches.length < 2) pinch = null;
  };
  container.addEventListener("touchend", end);
  container.addEventListener("touchcancel", end);
}

function zoomButton(
  label: string,
  ariaLabel: string,
  onClick: () => void,
): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "diagram-zoom-button";
  button.textContent = label;
  button.setAttribute("aria-label", ariaLabel);
  button.addEventListener("click", onClick);
  return button;
}

function openDiagramFullscreen(
  diagram: HTMLElement,
  expandButton: HTMLButtonElement,
): void {
  const placeholder = document.createComment("diagram position");
  diagram.before(placeholder);

  const dialog = document.createElement("dialog");
  dialog.className = "diagram-fullscreen";
  dialog.setAttribute("aria-label", "Expanded architecture diagram");

  const toolbar = document.createElement("div");
  toolbar.className = "diagram-fullscreen-toolbar";
  const title = document.createElement("span");
  title.className = "diagram-fullscreen-title";
  title.textContent = "Architecture diagram";
  const hint = document.createElement("span");
  hint.className = "diagram-zoom-hint";
  hint.textContent =
    " drag to pan · pinch, double-tap, + / − or Ctrl+scroll to zoom · 0 to reset";
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
  // The inline diagram may carry a pinch zoom; fullscreen sizes the box with
  // explicit pixels instead, so park `style.zoom` while the dialog is open.
  const inlineZoomStyle = diagram.style.zoom;
  diagram.style.removeProperty("zoom");
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
    )
      content.setAttribute("data-pannable", "");
    else content.removeAttribute("data-pannable");
  };
  const stepZoom = (direction: number) => {
    zoom = clampZoom(zoom + direction * ZOOM_STEP);
    applyZoom();
  };
  const resetZoom = () => {
    zoom = 1;
    applyZoom();
  };
  // Zoom around a fixed screen point — the pinch midpoint or the double-tap —
  // so the part of the diagram under the fingers stays where they are.
  const zoomAt = (value: number, clientX: number, clientY: number) => {
    zoom = clampZoom(value);
    anchorZoom(content, diagram, clientX, clientY, applyZoom);
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
  let pan: {
    pointerId: number;
    x: number;
    y: number;
    left: number;
    top: number;
  } | null = null;
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
    try {
      content.setPointerCapture(event.pointerId);
    } catch {}
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
    try {
      content.releasePointerCapture(event.pointerId);
    } catch {}
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

  // Touch gestures on the diagram: attachPinchZoom handles two-finger pinch,
  // and a double-tap here toggles zoom centered on the tapped spot.
  // `touch-action: pan-x pan-y` on the content (stylesheet) keeps the browser
  // from page-zooming and double-tap-zooming inside the dialog, so the gestures
  // reach these handlers instead.
  const TAP_SLOP = 10; // px of travel that still counts as a tap
  const DOUBLE_TAP_MS = 300;
  const DOUBLE_TAP_DISTANCE = 32;
  let pinchSeen = false; // a two-finger gesture started and a finger may still be down
  let tap: { x: number; y: number; time: number; moved: boolean } | null = null;
  let lastTap: { x: number; y: number; time: number } | null = null;
  attachPinchZoom(content, () => zoom, zoomAt);
  content.addEventListener("touchstart", (event) => {
    if (event.touches.length === 2) {
      pinchSeen = true;
      tap = null;
    } else if (event.touches.length === 1 && !pinchSeen) {
      const touch = event.touches[0];
      tap = {
        x: touch.clientX,
        y: touch.clientY,
        time: Date.now(),
        moved: false,
      };
    }
  });
  content.addEventListener("touchmove", (event) => {
    // Scrolling disqualifies the gesture as a tap, but never blocks the scroll.
    if (event.touches.length === 1 && tap && !tap.moved) {
      const touch = event.touches[0];
      if (Math.hypot(touch.clientX - tap.x, touch.clientY - tap.y) > TAP_SLOP)
        tap.moved = true;
    }
  });
  content.addEventListener("touchend", (event) => {
    if (event.touches.length > 0) return; // fingers are still down
    if (pinchSeen) {
      // A pinch just ended: its trailing finger-lifts must not count as taps.
      pinchSeen = false;
      tap = null;
      lastTap = null;
      return;
    }
    const now = Date.now();
    const touch = event.changedTouches[0];
    if (tap && !tap.moved && touch && now - tap.time <= DOUBLE_TAP_MS) {
      const { clientX, clientY } = touch;
      const paired =
        lastTap !== null &&
        now - lastTap.time <= DOUBLE_TAP_MS &&
        Math.hypot(clientX - lastTap.x, clientY - lastTap.y) <=
          DOUBLE_TAP_DISTANCE;
      if (paired) {
        lastTap = null;
        // Out to 100% when zoomed in, in by 2× otherwise — pinned to the tap.
        zoomAt(zoom > 1 ? 1 : zoom * 2, clientX, clientY);
        // Stops iOS from stacking its own double-tap zoom on top of ours.
        event.preventDefault();
      } else {
        lastTap = { x: clientX, y: clientY, time: now };
      }
    } else {
      lastTap = null; // a scroll or a slow press breaks the pair
    }
    tap = null;
  });
  content.addEventListener("touchcancel", (event) => {
    if (event.touches.length === 0) {
      pinchSeen = false;
      tap = null;
      lastTap = null;
    }
  });
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
  dialog.addEventListener(
    "close",
    () => {
      document.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("resize", applyZoom);
      diagram.style.removeProperty("width");
      diagram.style.removeProperty("height");
      diagram.style.removeProperty("box-sizing");
      diagram.style.removeProperty("zoom");
      // Back to the inline view — including any pinch zoom it had before Expand.
      if (inlineZoomStyle) diagram.style.zoom = inlineZoomStyle;
      if (svg) {
        if (svgOriginalStyle === null) svg.removeAttribute("style");
        else svg.setAttribute("style", svgOriginalStyle);
      }
      placeholder.replaceWith(diagram);
      dialog.remove();
      expandButton.focus();
    },
    { once: true },
  );

  // showModal first: the dialog is display:none until open, so clientWidth/
  // Height would read 0 before it.
  dialog.showModal();
  applyZoom();
  close.focus();
}

let cachedMermaid: typeof import("mermaid").default | null = null;

async function loadMermaid(): Promise<typeof import("mermaid").default> {
  if (cachedMermaid) return cachedMermaid;
  const mod = await import("mermaid");
  cachedMermaid = mod.default;
  return cachedMermaid;
}

async function renderMermaidDiagrams(): Promise<void> {
  const theme = document.documentElement.classList.contains("dark")
    ? "dark"
    : "default";
  const diagrams = Array.from(
    document.querySelectorAll<HTMLElement>("pre.mermaid"),
  );
  const needRender = diagrams.filter(
    (diagram) => diagram.dataset.mermaidTheme !== theme,
  );

  if (needRender.length === 0) {
    addDiagramExpandButtons();
    return;
  }

  try {
    const mermaid = await loadMermaid();
    for (const diagram of needRender) {
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
    await mermaid.run({ querySelector: ".mermaid:not([data-processed])" });
    // Fallback: if any diagram still has raw text (mermaid.run skipped it),
    // render it individually. This can happen when querySelector misses a
    // freshly-prepared node or when a prior data-processed flag survives.
    const remaining = Array.from(
      document.querySelectorAll<HTMLElement>(".mermaid:not([data-processed])"),
    );
    for (const diagram of remaining) {
      const source = diagram.dataset.mermaidSource ?? diagram.textContent ?? "";
      if (source.trim().length === 0) continue;
      try {
        const id = `mermaid-fallback-${Date.now()}-${Math.random().toString(36).slice(2)}`;
        diagram.setAttribute("data-processed", "true");
        const result = await mermaid.render(id, source);
        const svg = result?.svg;
        if (svg && svg !== diagram.innerHTML) {
          diagram.innerHTML = svg;
        }
      } catch (inner) {
        console.warn("Could not render one architecture diagram:", inner);
      }
    }
    for (const diagram of needRender) {
      diagram.dataset.mermaidTheme = theme;
    }
  } catch (error) {
    console.error("Could not render architecture diagrams:", error);
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
          renderQueue = renderQueue
            .then(renderMermaidDiagrams)
            .catch((error: unknown) => {
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
              ? h(
                  "a",
                  {
                    class: "beta-badge",
                    href: "/guide/beta-roadmap",
                    target: "_self",
                  },
                  "beta",
                )
              : null,
          "layout-top": () =>
            __DOCS_VERSION__
              ? h("div", { class: "version-banner" }, [
                  `You are reading the docs for ${__DOCS_VERSION__}. `,
                  h(
                    "a",
                    { href: "/", target: "_self" },
                    "View the latest docs",
                  ),
                  ".",
                ])
              : null,
        });
    },
  },
} satisfies Theme;
