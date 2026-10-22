import { onCleanup } from "solid-js";
import type { ViewerLocation } from "./router";
import { forestRepo } from "./router";
import { mapOpen, openMap } from "./mapState";
import { storySheetOpen } from "./StorySheet";

// The node review keyboard: c flips diffs⇄commits ([ / ] step commits there), b toggles the file
// panel, ⇧B/⇧U bless/unbless the focused file, o opens the hovered line in nvim, Esc opens the
// forest map overlay (m does too, from anywhere — MapOverlay), ? toggles help. Installed on
// mount, torn down on cleanup.
export function useNodeKeyboard(deps: {
  focusFilter: () => void;
  hover: () => { path: string; line: number } | null;
  openInNvim: (path: string, line: number | null) => void;
  setView: (fn: (v: "diffs" | "commits") => "diffs" | "commits") => void;
  view: () => "diffs" | "commits";
  stepCommit: (delta: number) => void;
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
    // a sheet over the page owns the keyboard: Esc there closes the sheet rather than also
    // popping up to the forest map
    if (storySheetOpen() || mapOpen()) return;
    if ((e.metaKey || e.ctrlKey) && e.key === "f") { e.preventDefault(); deps.focusFilter(); return; }
    if (e.metaKey || e.ctrlKey || e.altKey) return; // leave OS/browser chords alone
    if (e.key === "o" && deps.hover()) { e.preventDefault(); const h = deps.hover()!; deps.openInNvim(h.path, h.line); }
    else if (e.key === "c") deps.setView((v) => (v === "commits" ? "diffs" : "commits"));
    else if ((e.key === "[" || e.key === "]") && deps.view() === "commits") { e.preventDefault(); deps.stepCommit(e.key === "]" ? 1 : -1); }
    else if (e.key === "b") { e.preventDefault(); deps.togglePanel(); } // show / hide the file panel
    // ⇧B blesses the focused file and advances (B·B·B down a branch, no mouse); ⇧U unblesses it in
    // place. Per-file only — there is deliberately no bless-all key.
    // advance in the next frame — after the just-blessed card collapses — so the scroll lands the
    // next card at the toolbar line instead of over-shooting past the freed-up space.
    else if (e.key === "B" && deps.activeFile() && deps.base() === "") { e.preventDefault(); deps.onBless(deps.activeFile()); requestAnimationFrame(() => deps.onFileCycleNext()); }
    else if (e.key === "U" && deps.activeFile() && deps.base() === "") { e.preventDefault(); deps.onUnbless(deps.activeFile()); }
    else if (e.key === "?") { e.preventDefault(); deps.setShowHelp((v) => !v); }
    else if (e.key === "Escape") {
      // up a level: help → close it; else → the forest map
      if (deps.showHelp()) { deps.setShowHelpTo(false); }
      else { const p = deps.project(); if (p) { openMap({ name: p, repo: forestRepo(deps.location()) }); } }
    }
  };
  window.addEventListener("keydown", onKey);
  onCleanup(() => window.removeEventListener("keydown", onKey));
}
