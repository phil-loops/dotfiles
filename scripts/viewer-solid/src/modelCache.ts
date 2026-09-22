import type { ForestModel } from "./types";

// Same bet as projectsCache, for the thing the forest page IS: a cold server rebuilds a forest
// model from ~25 serial git spawns, and the map stayed blank until it landed. Paint the last
// map this browser saw at once, then revalidate. Keyed per repo+forest; one entry each, so a
// wide-ranging session can't grow the quota without bound.
const KEY = (repo: string, forest: string) => `viewerModelCache:${repo}:${forest}`;

export const cachedModel = (repo: string, forest: string): ForestModel | undefined => {
  try {
    const s = localStorage.getItem(KEY(repo, forest));
    return s ? (JSON.parse(s) as ForestModel) : undefined;
  } catch {
    return undefined;
  }
};

export const rememberModel = (repo: string, forest: string, d: ForestModel | undefined): void => {
  if (d && Object.keys(d.nodes ?? {}).length) {
    try { localStorage.setItem(KEY(repo, forest), JSON.stringify(d)); } catch { /* quota/private mode — skip */ }
  }
};
