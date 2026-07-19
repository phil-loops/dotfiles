import { createSignal } from "solid-js";
import { buildPath, type ViewerLocation } from "./router";
import { leaf } from "./shared";

// recently-accessed places for the nav rail. Module-scope and fed from Layout's route effect,
// not the rail's render — the rail is hidden on node review, but a deep-linked branch or PR
// should still register.
export type RecentCtx = { label: string; to: ViewerLocation };

const RECENTS_KEY = "viewerRecentContexts";
const read = (): RecentCtx[] => {
  try {
    const s = localStorage.getItem(RECENTS_KEY);
    if (s) return JSON.parse(s);
    const old = localStorage.getItem("viewerLastContext"); // predecessor: single lingering tile
    return old ? [JSON.parse(old)] : [];
  } catch {
    return [];
  }
};
const save = (next: RecentCtx[]) => {
  try { localStorage.setItem(RECENTS_KEY, JSON.stringify(next)); } catch { /* quota/private mode — skip */ }
};

export const [recents, setRecents] = createSignal<RecentCtx[]>(read());

// the place a location stands in, when it's deeper than home.
export const contextOf = (l: ViewerLocation): RecentCtx | null => {
  if (l.kind === "forest") {
    return { label: leaf(l.name), to: { kind: "forest", name: l.name, repo: l.repo } };
  }
  if (l.kind === "standalone") {
    return { label: leaf(l.branch), to: { kind: "standalone", branch: l.branch } };
  }
  if (l.kind === "review") {
    return { label: `PR ${l.pr}`, to: { kind: "review", pr: l.pr } };
  }
  return null;
};

export const trackRecent = (l: ViewerLocation): void => {
  const c = contextOf(l);
  if (!c) return;
  const key = buildPath(c.to);
  setRecents((r) => {
    const next = [c, ...r.filter((x) => buildPath(x.to) !== key)].slice(0, 6);
    save(next);
    return next;
  });
};

export const dismissRecent = (to: ViewerLocation): void => {
  const key = buildPath(to);
  setRecents((r) => {
    const next = r.filter((x) => buildPath(x.to) !== key);
    save(next);
    return next;
  });
};
