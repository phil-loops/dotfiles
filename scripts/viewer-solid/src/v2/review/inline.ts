// The outgoing change read commit by commit (the Commits tab): each unpushed commit's own diff
// (GET /commit-diff), drawn under its message. Their expanded context and folds live here, keyed
// by commit, so the commands that change them (inline.expand, inline.fold) can reach them.
import { createSignal } from "solid-js";
import { getJSON, getText } from "../sync";
import type { NodeFile } from "./page";

/** a commit's diff above this many changed lines arrives folded, with a diffstat */
export const FOLD_OVER = 150;

const [diffs, setDiffs] = createSignal<ReadonlyMap<string, NodeFile[]>>(new Map());
const [texts, setTexts] = createSignal<ReadonlyMap<string, string[]>>(new Map());
const [reveals, setReveals] = createSignal<ReadonlyMap<string, ReadonlyMap<number, number>>>(new Map());
const [folds, setFolds] = createSignal<ReadonlyMap<string, boolean>>(new Map());
const asking = new Set<string>();

export { diffs, folds, reveals, texts };

/** Read a commit's own diff once. */
export function loadDiff(repoPath: (p: string) => string, sha: string): void {
  if (diffs().has(sha) || asking.has(sha)) return;
  asking.add(sha);
  void getJSON<{ files: NodeFile[] }>(repoPath(`/commit-diff?sha=${encodeURIComponent(sha)}`))
    .then((d) => setDiffs((m) => new Map(m).set(sha, d.files)))
    .catch(() => {})
    .finally(() => asking.delete(sha));
}

/** `<sha>|<path>`: one commit's version of one file. */
export const fileKey = (sha: string, path: string) => `${sha}|${path}`;

/** Show `n` more hidden lines at a gap of one commit's file; reads the file at that commit once. */
export function revealAt(repoPath: (p: string) => string, sha: string, path: string, at: number, n = 20): void {
  const k = fileKey(sha, path);
  setReveals((m) => new Map(m).set(k, new Map(m.get(k) ?? []).set(at, (m.get(k)?.get(at) ?? 0) + n)));
  if (texts().has(k) || asking.has(k)) return;
  asking.add(k);
  void getText(repoPath(`/file?branch=${encodeURIComponent(sha)}&path=${encodeURIComponent(path)}`))
    .then((t) => t != null && setTexts((m) => new Map(m).set(k, t.split("\n"))))
    .finally(() => asking.delete(k));
}

/** Folded: the commit's own choice if it was toggled, else folded when it's large. */
export const isFolded = (sha: string, changed: number) => folds().get(sha) ?? changed > FOLD_OVER;
export const toggleFold = (sha: string, changed: number) => setFolds((m) => new Map(m).set(sha, !isFolded(sha, changed)));
