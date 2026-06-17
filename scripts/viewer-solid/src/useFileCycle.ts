import { onCleanup } from "solid-js";

// useFileCycle — Tab / Shift+Tab jump through the modified-file diff cards in the current
// node, the way nvim's <leader>gm steps through changed files. Stepping the spine node-by-node
// with j/k isn't the useful motion during review; cycling the *files* is. Driven off the
// rendered `.entry[data-path]` cards (no app state needed) — hook it once inside NodeDetail.
//
// First Tab drops a cursor on the file nearest the top of the viewport; subsequent Tab /
// Shift+Tab move forward / backward through the files and wrap at the ends. The current file
// gets a gold outline and scrolls into view (offset below the toolbar). Ignored while typing
// in an input so the ask-Claude / watch fields keep normal Tab behavior.
export function useFileCycle(options: { selector?: string; offsetTop?: number } = {}) {
  const SEL = options.selector ?? ".entry[data-path]";
  const offset = options.offsetTop ?? 80;
  let currentPath: string | null = null;
  let lit: HTMLElement | null = null;

  const entries = (): { path: string; el: HTMLElement }[] =>
    [...document.querySelectorAll<HTMLElement>(SEL)].map((el) => ({
      path: el.getAttribute("data-path") || "",
      el,
    }));

  const highlight = (el: HTMLElement) => {
    if (lit && lit !== el) {
      lit.style.outline = "";
      lit.style.outlineOffset = "";
    }
    el.style.outline = "2px solid var(--gold, #e0ad4e)";
    el.style.outlineOffset = "3px";
    el.style.scrollMarginTop = `${offset}px`;
    lit = el;
  };

  // first file whose top sits at/below the toolbar — i.e. the "next" file from where you are
  const nearTop = (list: { el: HTMLElement }[]): number => {
    for (let i = 0; i < list.length; i++) {
      if (list[i].el.getBoundingClientRect().top >= offset - 8) return i;
    }
    return Math.max(0, list.length - 1);
  };

  const move = (dir: 1 | -1) => {
    const list = entries();
    if (!list.length) return;
    let idx = currentPath ? list.findIndex((e) => e.path === currentPath) : -1;
    if (idx < 0) {
      // no cursor yet (or it scrolled out of the DOM on a node change) — start near the top
      idx = nearTop(list);
      if (dir < 0) idx = Math.max(0, idx - 1);
    } else {
      idx = (idx + dir + list.length) % list.length; // wrap at the ends
    }
    const { path, el } = list[idx];
    currentPath = path;
    highlight(el); // sets scroll-margin-top FIRST so the scroll clears the toolbar
    el.scrollIntoView({ block: "start" });
  };

  const onKey = (e: KeyboardEvent) => {
    if (e.key !== "Tab") return;
    const t = e.target as HTMLElement | null;
    if (t && t.matches?.("input, textarea, [contenteditable]")) return; // don't hijack typing
    e.preventDefault();
    move(e.shiftKey ? -1 : 1);
  };
  window.addEventListener("keydown", onKey);
  onCleanup(() => window.removeEventListener("keydown", onKey));
}
