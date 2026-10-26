// Rewording a branch's unpushed commits: one save rewrites every changed message in a single
// guarded pass (POST /outline — same trees, refuses if the branch moved since it was read,
// reseats descendants), and u replays /outline-undo.
import { atRepo } from "../model";
import { command } from "../registry";
import { view } from "../store";
import { changed, drafts, editPr, editTo, hintsOf, PR, prChange, prHints, prOnFile, prValue, savedPr, setDrafts, setSavedPr, shown, valueOf } from "../words";

command({
  id: "words.save",
  title: "Save the commit message edits",
  scope: "global",
  budget: "git-write",
  quiet: true,
  available: (id) => !!id && (changed(id).length > 0 || !!prChange(id)),
  write: (id) => {
    const b = view("branch", id);
    const o = shown.get(id);
    const edits = changed(id);
    const pr = prChange(id);
    if (!b || !o || (!edits.length && !pr)) return null;
    if (edits.some((e) => !e.subject)) throw new Error("a commit needs a subject");
    const was = drafts();
    const mine = new Map(was.get(id) ?? []);
    const prBefore = prOnFile(id);
    const prAfter = pr ? prValue(id) : null;
    for (const e of edits) mine.delete(e.sha);
    if (pr) mine.delete(PR);
    setDrafts(new Map(was).set(id, mine));
    const savedWas = savedPr();
    if (prAfter) setSavedPr(new Map(savedWas).set(id, { subject: prAfter.subject.trim(), body: prAfter.body.trim() }));
    const n = edits.length;
    const what = [n ? `reworded ${n} commit${n === 1 ? "" : "s"}` : "", pr ? "saved the PR text" : ""].filter(Boolean).join(", ");
    return {
      ops: [],
      path: atRepo(b.repo, "/outline"),
      body: { branch: b.name, head: o.head, edits, ...(pr ?? {}) },
      // rewording moves the tip; a PR-text-only save lands in config, done when the server answers
      settled: () => !n || view("branch", id)?.tip !== o.head,
      said: `${what} · u undoes`,
      failed: "couldn't save — the branch may have moved; your edits are kept",
      rollback: () => {
        setDrafts(was);
        setSavedPr(savedWas);
      },
      inverse: { id: "words.undo", target: id, arg: { moves: n > 0, pr: pr ? prBefore : null } },
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
    if (sha === PR) {
      const fix = prHints(id).find((h) => h.id === hint)?.fix;
      if (!fix) throw new Error("that hint has nothing to fix any more");
      return editPr(id, fix.apply(prValue(id)));
    }
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
  write: (id, arg) => {
    const b = view("branch", id);
    if (!b) return null;
    const tip = b.tip;
    const { moves = true, pr = null } = (arg ?? {}) as { moves?: boolean; pr?: { subject: string; body: string } | null };
    const savedWas = savedPr();
    if (pr) setSavedPr(new Map(savedWas).set(id, pr));
    return {
      ops: [],
      path: atRepo(b.repo, "/outline-undo"),
      body: { branch: b.name },
      settled: () => !moves || view("branch", id)?.tip !== tip,
      rollback: () => setSavedPr(savedWas),
      said: "undone",
      failed: "couldn't put the messages back",
    };
  },
});
