import { onCleanup } from "solid-js";
import type { ViewerLocation } from "./router";
import { forestRepo } from "./router";
import { chatTarget } from "./chatDrawer";
import type { SpineNode } from "./types";

// The node review keyboard: j/k walk the spine, 1–4 pick the diff base, c flips diffs⇄commits,
// b toggles the file panel, ⇧B/⇧U bless/unbless the focused file, o opens the hovered line in
// nvim, m/Esc go up to the forest, ? toggles help. Installed on mount, torn down on cleanup.
export function useNodeKeyboard(deps: {
  focusFilter: () => void;
  spine: () => SpineNode[];
  active: () => string;
  goto: (b: string) => void;
  setBase: (v: string) => void;
  hover: () => { path: string; line: number } | null;
  openInNvim: (path: string, line: number | null) => void;
  setView: (fn: (v: "diffs" | "commits") => "diffs" | "commits") => void;
  togglePanel: () => void;
  activeFile: () => string;
  base: () => string;
  onBless: (file: string) => void;
  onFileCycleNext: () => void;
  onUnbless: (file: string) => void;
  showHelp: () => boolean;
  setShowHelp: (fn: (v: boolean) => boolean) => void;
  setShowHelpTo: (v: boolean) => void;
  project: () => string;
  navigate: (loc: ViewerLocation) => void;
  location: () => ViewerLocation;
}) {
  const onKey = (e: KeyboardEvent) => {
    // already typing (incl. the filter box) → let everything bubble: a 2nd ⌘F reaches native find
    if ((e.target as Element).matches("input, textarea, [contenteditable]")) return;
    if ((e.metaKey || e.ctrlKey) && e.key === "f") { e.preventDefault(); deps.focusFilter(); return; }
    if (e.metaKey || e.ctrlKey || e.altKey) return; // leave OS/browser chords alone
    const list = deps.spine();
    const i = list.findIndex((n) => n.id === deps.active());
    if (e.key === "j" && i < list.length - 1) { e.preventDefault(); deps.goto(list[i + 1].id); }
    else if (e.key === "k" && i > 0) { e.preventDefault(); deps.goto(list[i - 1].id); }
    else if (e.key === "1") deps.setBase("");
    else if (e.key === "2") deps.setBase("main");
    else if (e.key === "3") deps.setBase("blessed");
    else if (e.key === "4") deps.setBase("@origin");
    else if (e.key === "o" && deps.hover()) { e.preventDefault(); const h = deps.hover()!; deps.openInNvim(h.path, h.line); }
    else if (e.key === "c") deps.setView((v) => (v === "commits" ? "diffs" : "commits"));
    else if (e.key === "b") { e.preventDefault(); deps.togglePanel(); } // show / hide the file panel
    // ⇧B blesses the focused file and advances (B·B·B down a branch, no mouse); ⇧U unblesses it in
    // place. Per-file only — there is deliberately no bless-all key.
    // advance in the next frame — after the just-blessed card collapses — so the scroll lands the
    // next card at the toolbar line instead of over-shooting past the freed-up space.
    else if (e.key === "B" && deps.activeFile() && deps.base() === "") { e.preventDefault(); deps.onBless(deps.activeFile()); requestAnimationFrame(() => deps.onFileCycleNext()); }
    else if (e.key === "U" && deps.activeFile() && deps.base() === "") { e.preventDefault(); deps.onUnbless(deps.activeFile()); }
    else if (e.key === "?") { e.preventDefault(); deps.setShowHelp((v) => !v); }
    else if (e.key === "m") {
      // m → up to the forest view. The key reached for by muscle memory (Esc does it too).
      e.preventDefault();
      const p = deps.project();
      if (p) deps.navigate({ kind: "forest", name: p, repo: forestRepo(deps.location()) });
    }
    else if (e.key === "Escape") {
      // up a level: help → close it; else (when the chat drawer isn't grabbing Esc) → the forest map
      if (deps.showHelp()) { deps.setShowHelpTo(false); }
      else if (!chatTarget()) { const p = deps.project(); if (p) { deps.navigate({ kind: "forest", name: p, repo: forestRepo(deps.location()) }); } }
    }
  };
  window.addEventListener("keydown", onKey);
  onCleanup(() => window.removeEventListener("keydown", onKey));
}
