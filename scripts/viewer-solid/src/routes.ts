// Central route + path builders for the HashRouter (see App's <HashRouter>).
//
//   /                      home — your ledger summary
//   /*forest               a forest (or a standalone branch) — `forest` is a splat
//                          param so branch names with slashes ride through literally
//   /*forest?node=<branch> a specific node within that forest
//
// `forest` is whatever /model?branch= wants (a forest project tag, OR a loose
// branch name with slashes), so it must be a splat — not a single segment. `node`
// also carries slashes, so it travels as a search param (the router encodes it).
export const homePath = (): string => "/";
export const forestPath = (forest: string): string => "/" + forest;
export const nodePath = (forest: string, node: string): string =>
  "/" + forest + "?node=" + encodeURIComponent(node);
