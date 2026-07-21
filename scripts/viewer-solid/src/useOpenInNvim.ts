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
  const note = (m: string, ms = 1900) => { setFlash(m); clearTimeout(flashT); flashT = setTimeout(() => setFlash(""), ms); };
  // stack-open reports one-line diagnoses on stderr ("'x.ts' not in <branch>", a parked zombie
  // worktree, a line past EOF) and the server forwards them — showing them beats "see server",
  // which sent you to a log the open path never writes to.
  const why = (r: { err?: string; out?: string }) =>
    ((r.err || r.out || "").trim().split("\n").filter(Boolean).pop() || "open failed")
      .replace(/^stack-open: /, "").slice(0, 140);
  const openInNvim = (path: string, line: number | null) => {
    if (!canMutate) return undefined; // static snapshot: no live nvim to open into
    // no auto-clear on this one — the "opening…" chip holds until the result note replaces it
    clearTimeout(flashT);
    setFlash(`⌁ opening ${leaf(path)}${line != null ? `:${line}` : ""}…`);
    return fetch(withRepo("/open"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ branch: deps.nodeRef(), path, ...(line != null ? { pos: String(line) } : {}) }),
    })
      .then((r) => r.json())
      .then((r) => (r.ok ? note(`⌁ ${leaf(path)}:${line ?? ""} → nvim`) : note(`⌁ ${why(r)}`, 6000)))
      .catch(() => note("⌁ open failed — server unreachable"));
  };
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
