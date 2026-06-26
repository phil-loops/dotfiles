import { createSignal } from "solid-js";
import type { FileDiff } from "./types";
import type { ViewerLocation } from "./router";

// The open chat drawer, hoisted to module scope so it OUTLIVES route changes — the drawer is
// rendered once at the always-mounted Layout level, not inside the per-node view. `branch`/`origin`
// pin it to where it was opened, so navigating elsewhere leaves it intact and it can navigate back.
// file null → chat about the whole branch.
//
// It also survives a page RELOAD: which chat is open + its minimized state are mirrored to
// localStorage. The conversation itself lives in chatStore, and reconcileChats() re-attaches any
// in-flight turn, so a restored drawer shows its history and live working…/done status. We persist
// only the file PATH (not its diff) — a restored chat resumes by session id and never needs to
// re-seed the diff.
export type ChatTarget = { branch: string; origin: ViewerLocation; file: FileDiff | null };

const KEY = "stack-chat-drawer";

function load(): { target: ChatTarget | null; minimized: boolean } {
  try {
    const d = JSON.parse(localStorage.getItem(KEY) || "null");
    if (!d || typeof d.branch !== "string" || !d.origin) {
      return { target: null, minimized: false };
    }
    const file = d.path ? { path: d.path, status: "modified" as const } : null;
    return { target: { branch: d.branch, origin: d.origin, file }, minimized: !!d.minimized };
  } catch {
    return { target: null, minimized: false };
  }
}

const initial = load();
const [target, setTarget] = createSignal<ChatTarget | null>(initial.target);
const [minimized, setMinimized] = createSignal(initial.minimized);

function persist() {
  const t = target();
  if (!t) {
    localStorage.removeItem(KEY);
    return;
  }
  localStorage.setItem(
    KEY,
    JSON.stringify({ branch: t.branch, origin: t.origin, path: t.file?.path ?? "", minimized: minimized() }),
  );
}

export const chatTarget = target;
export const drawerMinimized = minimized;

export const openChat = (t: ChatTarget) => {
  setTarget(t);
  setMinimized(false);
  persist();
};
export const closeChat = () => {
  setTarget(null);
  persist();
};
export const setDrawerMinimized = (v: boolean) => {
  setMinimized(v);
  persist();
};
