// Rewording a branch's unpushed commits: one save rewrites every changed message in a single
// guarded pass (POST /outline — same trees, refuses if the branch moved since it was read,
// reseats descendants), and u replays /outline-undo.
import { atRepo } from "../model";
import { command } from "../registry";
import { view } from "../store";
import { changed, drafts, editTo, hintsOf, setDrafts, shown, valueOf } from "../words";

command({
  id: "words.save",
  title: "Save the commit message edits",
  scope: "global",
  budget: "git-write",
  quiet: true,
  available: (id) => !!id && changed(id).length > 0,
  write: (id) => {
    const b = view("branch", id);
    const o = shown.get(id);
    const edits = changed(id);
    if (!b || !o || !edits.length) return null;
    if (edits.some((e) => !e.subject)) throw new Error("a commit needs a subject");
    const was = drafts();
    const mine = new Map(was.get(id) ?? []);
    for (const e of edits) mine.delete(e.sha);
    setDrafts(new Map(was).set(id, mine));
    const n = edits.length;
    return {
      ops: [],
      path: atRepo(b.repo, "/outline"),
      body: { branch: b.name, head: o.head, edits },
      settled: () => view("branch", id)?.tip !== o.head,
      said: `reworded ${n} commit${n === 1 ? "" : "s"} — u puts ${n === 1 ? "it" : "them"} back`,
      failed: "couldn't save — the branch may have moved; your edits are kept",
      rollback: () => setDrafts(was),
      inverse: { id: "words.undo", target: id },
    };
  },
});

command({
  id: "words.fix",
  title: "Apply a hint's fix to a commit message",
  scope: "global",
  budget: "local",
  quiet: true,
  local: (t) => {
    const [id, sha, hint] = (t ?? "").split(" ");
    const c = shown.get(id)?.commits.find((x) => x.sha === sha);
    const fix = c && hintsOf(id, c).find((h) => h.id === hint)?.fix;
    if (!c || !fix) throw new Error("that hint has nothing to fix any more");
    editTo(id, c, fix.apply(valueOf(id, c)));
  },
});

command({
  id: "words.undo",
  title: "Put the commit messages back as they were",
  scope: "global",
  budget: "git-write",
  quiet: true,
  write: (id) => {
    const b = view("branch", id);
    if (!b) return null;
    const tip = b.tip;
    return {
      ops: [],
      path: atRepo(b.repo, "/outline-undo"),
      body: { branch: b.name },
      settled: () => view("branch", id)?.tip !== tip,
      said: "messages put back",
      failed: "couldn't put the messages back",
    };
  },
});
