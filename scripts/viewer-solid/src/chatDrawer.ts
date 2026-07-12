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
// project set → a whole-forest chat (branch holds the project name as the thread key, file null).
export type ChatTarget = { branch: string; origin: ViewerLocation; file: FileDiff | null; project?: string };

const KEY = "stack-chat-drawer";

function load(): { target: ChatTarget | null; minimized: boolean } {
  try {
    const d = JSON.parse(localStorage.getItem(KEY) || "null");
    if (!d || typeof d.branch !== "string" || !d.origin) {
      return { target: null, minimized: false };
    }
    const file = d.path ? { path: d.path, status: "modified" as const } : null;
    return { target: { branch: d.branch, origin: d.origin, file, project: d.project || undefined }, minimized: !!d.minimized };
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
    JSON.stringify({ branch: t.branch, origin: t.origin, path: t.file?.path ?? "", project: t.project ?? "", minimized: minimized() }),
  );
}

export const chatTarget = target;
export const drawerMinimized = minimized;

// ✦ buttons' target (Phil, 2026-07-06): the chat is most useful IN TMUX, beside his other
// panes — the buttons launch an interactive claude there (split into the active window,
// even-horizontal columns), seeded exactly like a drawer chat. Fire-and-forget; the pane
// appearing is the feedback. The drawer stays for streamed edit-actions + running threads.
// `session` (a live session id from /claude-sessions) redirects the seed: instead of spawning
// a pane, the one-liner is drafted (never submitted) into that session's composer.
export const chatToTmux = (body: { branch?: string; project?: string; path?: string; patch?: string; session?: string }) =>
  fetch("/chat-tmux", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }).then((r) => r.json() as Promise<{ ok?: boolean; err?: string }>);

// The live Claude Code sessions the ✦ picker can draft into (presence registry, pane-resolved).
export type LiveSession = {
  session_id: string; repo_name: string; branch: string; area: string;
  pane: string; addr: string; idle_s: number;
};
export const claudeSessions = () =>
  fetch("/claude-sessions").then((r) => r.json() as Promise<{ sessions: LiveSession[] }>);

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
