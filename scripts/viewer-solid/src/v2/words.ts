// A branch's commits as /outline tells them (srv/outline.py): oldest first, each with its whole
// message, author, date and whether a remote holds it. Shared by the review page's words (e) and
// the forest page; the latest read per branch is kept so commands can act on what was shown.
import { createSignal } from "solid-js";

export interface Commit {
  sha: string;
  short: string;
  subject: string;
  body: string;
  author: string;
  date: string;
  pushed: boolean;
  /** why it can't be reworded here (on a remote, a merge, carried from a dep), else "" */
  locked: string;
}
export interface Outline {
  branch: string;
  head: string;
  description: string;
  commits: Commit[];
  draft?: { title?: string };
}

export const shown = new Map<string, Outline>();
/** commit sha → the body a strip is writing, shown at once until the branch's new tip lands */
export const [stripping, setStripping] = createSignal<ReadonlyMap<string, string>>(new Map());
