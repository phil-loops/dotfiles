import { createSignal, onCleanup, type Accessor } from "solid-js";

// useDiffSelection — turn a plain mouse text-selection over diff2html *side-by-side* output
// into the shape the `/claude` endpoint wants, so reviewing-into-context is a sweep, not a
// line-by-line shift-click (see ../design-select-to-claude.md).
//
// Endpoint contract (scripts/srv/assist.py):
//   POST /claude { branch, selections: [{ path, ranges: [[start, end], …] }], instruction }
//
// Wiring contract: each rendered file's diff must live under an element carrying
//   data-path="<repo-relative path>"
// We attribute selected rows to a file via that attribute — NOT diff2html's parsed `a/… b/…`
// header, which we don't control. App.tsx already sets data-path on each FileEntry's
// <article> (it also drives the open-in-nvim line handler), so we reuse it.
//
// diff2html side-by-side DOM (confirmed against diff2html 3.4.56 templates):
//   .d2h-files-diff > .d2h-file-side-diff[0]  = LEFT / old side
//                   > .d2h-file-side-diff[1]  = RIGHT / new side
//     table > tbody.d2h-diff-tbody > tr
//       td.d2h-code-side-linenumber  → the line number text (empty on placeholder rows)
//       td > div.d2h-code-side-line  → the code
//
// We read new-side (right) line numbers; if a selection touches only the old side (e.g. you
// dragged over deleted lines) we fall back to old-side numbers so the ranges stay coherent —
// we never mix the two sides' numbering within one file.

export type SelectedFile = { path: string; ranges: [number, number][] };
export type DiffSelection = { files: SelectedFile[]; lineCount: number; fileCount: number };

export function useDiffSelection(options: { debounceMs?: number } = {}): {
  selection: Accessor<DiffSelection | null>;
  clear: () => void;
} {
  const debounceMs = options.debounceMs ?? 120;
  const [sel, setSel] = createSignal<DiffSelection | null>(null);

  const recompute = () => {
    const s = window.getSelection();
    if (!s || s.isCollapsed || s.rangeCount === 0) {
      setSel(null);
      return;
    }
    const ranges: Range[] = [];
    for (let i = 0; i < s.rangeCount; i++) {
      ranges.push(s.getRangeAt(i));
    }

    // path → { left: Set<lineNo>, right: Set<lineNo> }
    const byPath = new Map<string, { left: Set<number>; right: Set<number> }>();
    for (const tbody of document.querySelectorAll(".d2h-diff-tbody")) {
      const host = tbody.closest("[data-path]");
      if (!host) {
        continue;
      }
      const path = host.getAttribute("data-path");
      if (!path) {
        continue;
      }
      // The 2nd side panel in a pair is the new (right) side; treat a lone panel as new.
      const sideDiv = tbody.closest(".d2h-file-side-diff");
      const sides = sideDiv?.parentElement?.querySelectorAll(":scope > .d2h-file-side-diff");
      const isRight = sides && sides.length > 1 ? sides[1] === sideDiv : true;

      for (const tr of tbody.querySelectorAll("tr")) {
        if (!ranges.some((r) => r.intersectsNode(tr))) {
          continue;
        }
        const cell = tr.querySelector("td.d2h-code-side-linenumber");
        const n = parseInt((cell?.textContent || "").trim(), 10);
        if (!Number.isFinite(n)) {
          continue; // empty placeholder row — nothing to point at
        }
        let bucket = byPath.get(path);
        if (!bucket) {
          bucket = { left: new Set(), right: new Set() };
          byPath.set(path, bucket);
        }
        (isRight ? bucket.right : bucket.left).add(n);
      }
    }

    const files: SelectedFile[] = [];
    let lineCount = 0;
    for (const [path, { left, right }] of byPath) {
      const nums = right.size ? right : left; // prefer new-side; never mix sides
      if (!nums.size) {
        continue;
      }
      lineCount += nums.size;
      files.push({ path, ranges: toRanges(nums) });
    }
    setSel(files.length ? { files, lineCount, fileCount: files.length } : null);
  };

  let timer: ReturnType<typeof setTimeout> | undefined;
  const onSelectionChange = () => {
    clearTimeout(timer);
    timer = setTimeout(recompute, debounceMs);
  };
  document.addEventListener("selectionchange", onSelectionChange);
  onCleanup(() => {
    clearTimeout(timer);
    document.removeEventListener("selectionchange", onSelectionChange);
  });

  const clear = () => {
    window.getSelection()?.removeAllRanges();
    setSel(null);
  };

  return { selection: sel, clear };
}

// Collapse a set of line numbers into contiguous [start, end] pairs.
function toRanges(nums: Set<number>): [number, number][] {
  const sorted = [...nums].sort((a, b) => a - b);
  const out: [number, number][] = [];
  for (const n of sorted) {
    const last = out[out.length - 1];
    if (last && n === last[1] + 1) {
      last[1] = n;
    } else {
      out.push([n, n]);
    }
  }
  return out;
}
