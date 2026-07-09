import { createSignal } from "solid-js";
import { canMutate, withRepo } from "./provider";
import { leaf } from "./shared";

// hover a diff line + press o → open that exact line in the warm review-nvim. Hover-armed and
// event-delegated off the surface; no click-to-open (a click collided with text selection), so
// opening is keyboard-only. Returns the hover/flash state + the openInNvim + lineAt helpers.
export function useOpenInNvim(deps: { nodeRef: () => string }) {
  const [hover, setHover] = createSignal<{ path: string; line: number } | null>(null);
  const [flash, setFlash] = createSignal("");
  let flashT: ReturnType<typeof setTimeout>;
  const note = (m: string) => { setFlash(m); clearTimeout(flashT); flashT = setTimeout(() => setFlash(""), 1900); };
  const openInNvim = (path: string, line: number | null) =>
    !canMutate
      ? undefined // static snapshot: no live nvim to open into
      : fetch(withRepo("/open"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ branch: deps.nodeRef(), path, ...(line != null ? { pos: String(line) } : {}) }),
    })
      .then((r) => r.json())
      .then((r) => note(r.ok ? `⌁ ${leaf(path)}:${line ?? ""} → nvim` : "⌁ open failed — see server"))
      .catch(() => note("⌁ open failed — server unreachable"));
  const lineAt = (e: MouseEvent): { path: string; line: number } | null => {
    const target = e.target as Element | null;
    const ent = target?.closest<HTMLElement>(".entry");
    const tr = target?.closest<HTMLElement>("tr");
    if (!ent || !tr) return null;
    // arm anywhere in the row (code OR gutter) by reading that row's line-number cell —
    // not only when the cursor is over the tiny number itself
    const ln = tr.querySelector<HTMLElement>(".d2h-code-side-linenumber, .d2h-code-linenumber");
    const n = parseInt((ln?.textContent || "").trim(), 10);
    return Number.isFinite(n) ? { path: ent.dataset.path ?? "", line: n } : null;
  };
  return { hover, setHover, flash, openInNvim, lineAt };
}
