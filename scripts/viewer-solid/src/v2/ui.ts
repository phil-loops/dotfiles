// Local UI state the commands move: the cursor, the menu, the key sheet, the archive fold, which
// forests are open, the ready filter, an armed push, a launch in progress, a drag.
import { createSignal } from "solid-js";

/** The cursor holds a row key: "p:<project id>" or "b:<branch id>". */
export const [cursor, setCursor] = createSignal<string | undefined>();
export const [cursorIdx, setCursorIdx] = createSignal(0);
export const [menuOpen, setMenuOpen] = createSignal(false);
export const [sheetOpen, setSheetOpen] = createSignal(false);
export const [showArchive, setShowArchive] = createSignal(false);
export const [pendingKeys, setPendingKeys] = createSignal("");
export const [dashDays, setDashDays] = createSignal(30);

export const [expanded, setExpanded] = createSignal<ReadonlySet<string>>(new Set());
export const [readyOnly, setReadyOnly] = createSignal(false);
/** the branch whose push is waiting for its second keypress */
export const [armed, setArmed] = createSignal<string | undefined>();
/** the forest being launched: every node pushed and opened, top to bottom */
export const [launching, setLaunching] = createSignal<string | undefined>();
/** branches whose compare form was opened from here — "waiting for GitHub" until the PR shows */
/** tracker items showing their body */
export const [todoOpen, setTodoOpen] = createSignal<ReadonlySet<string>>(new Set());
export const [opened, setOpened] = createSignal<ReadonlySet<string>>(new Set());
/** a focus row being dragged: where it started, where it would land, how far the pointer moved */
export const [drag, setDrag] = createSignal<{ id: string; from: number; to: number; dy: number; h: number } | undefined>();

export const toggleIn = (set: ReadonlySet<string>, id: string, on?: boolean): ReadonlySet<string> => {
  const next = new Set(set);
  if (on ?? !next.has(id)) next.add(id);
  else next.delete(id);
  return next;
};

// The clock: ?now=<iso> pins it for screenshots and trials, and it keeps ticking from there.
const loadedAt = Date.now();
const pinned = Date.parse(new URLSearchParams(location.search).get("now") ?? "");
const read = () => (Number.isFinite(pinned) ? pinned + (Date.now() - loadedAt) : Date.now());
const [nowSig, setNow] = createSignal(read());
window.setInterval(() => setNow(read()), 30_000);
export const now = nowSig;
