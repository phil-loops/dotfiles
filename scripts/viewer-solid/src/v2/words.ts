// A branch's commits as /outline tells them (srv/outline.py): oldest first, each with its whole
// message, author, date and whether a remote holds it — and the edits waiting to be saved.
// Shared by the review page's words (e) and the forest page.
import { createSignal } from "solid-js";
import { hintsFor, type Words } from "../outlineHints";

export interface Commit {
  sha: string;
  short: string;
  subject: string;
  body: string;
  author: string;
  date: string;
  pushed: boolean;
  carried: boolean;
  /** why it can't be reworded here (on a remote, a merge, carried from a dep), else "" */
  locked: string;
}
export interface Outline {
  branch: string;
  head: string;
  description: string;
  ticket?: string;
  commits: Commit[];
  draft?: { title?: string };
}

/** the latest /outline read per branch id, so a save acts on exactly what was shown */
export const shown = new Map<string, Outline>();

/** unsaved message edits: branch id → commit sha → words. They outlive the overlay closing. */
export const [drafts, setDrafts] = createSignal<ReadonlyMap<string, ReadonlyMap<string, Words>>>(new Map());

export function setDraft(branchId: string, sha: string, w: Words | null): void {
  setDrafts((all) => {
    const mine = new Map(all.get(branchId) ?? []);
    if (w) mine.set(sha, w);
    else mine.delete(sha);
    return new Map(all).set(branchId, mine);
  });
}

/** The edits that would change a commit as it stands now — a draft back to the original isn't one. */
export function changed(branchId: string): { sha: string; subject: string; body: string }[] {
  const o = shown.get(branchId);
  const mine = drafts().get(branchId);
  if (!o || !mine) return [];
  return o.commits
    .filter((c) => !c.locked && mine.has(c.sha))
    .map((c) => ({ c, w: mine.get(c.sha)! }))
    .filter(({ c, w }) => w.subject.trim() !== c.subject || w.body.trim() !== c.body)
    .map(({ c, w }) => ({ sha: c.sha, subject: w.subject.trim(), body: w.body.trim() }));
}

/** A commit's words as they stand: the draft if there is one, else what git has. */
export function valueOf(branchId: string, c: Commit): Words {
  return drafts().get(branchId)?.get(c.sha) ?? { subject: c.subject, body: c.body };
}

/** v1's live hints for an unpushed commit — the opening commit wants the ticket's scope, follow-ups read bare. */
export function hintsOf(branchId: string, c: Commit) {
  const o = shown.get(branchId);
  if (!o || c.locked) return [];
  const opening = o.commits.find((x) => !x.carried)?.sha;
  return hintsFor(valueOf(branchId, c), { opening: c.sha === opening, ticket: o.ticket || undefined });
}

/** Record an edit; one that lands back on git's own words stops being a draft. */
export function editTo(branchId: string, c: Commit, w: Words): void {
  setDraft(branchId, c.sha, w.subject === c.subject && w.body === c.body ? null : w);
}
