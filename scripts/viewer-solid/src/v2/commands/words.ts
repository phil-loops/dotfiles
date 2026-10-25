// A commit message's generated forest plan, stripped in place: POST /outline rewrites the unpushed
// commit with the same tree (srv/outline.py — refuses if the branch moved since it was read), and
// u replays /outline-undo.
import { stripPlan } from "../../outlineHints";
import { atRepo } from "../model";
import { command } from "../registry";
import { view } from "../store";
import { setStripping, shown, stripping } from "../words";

const parse = (t: string | undefined) => {
  const [id, sha] = (t ?? "").split(" ");
  const o = id ? shown.get(id) : undefined;
  const c = o?.commits.find((x) => x.sha === sha);
  return o && c && view("branch", id) ? { id, o, c, b: view("branch", id)! } : null;
};

command({
  id: "words.strip",
  title: "Strip the forest plan from a commit message",
  scope: "global",
  budget: "git-write",
  quiet: true,
  available: (t) => {
    const p = parse(t);
    return !!p && !p.c.locked && stripPlan(p.c.body) !== p.c.body;
  },
  write: (t) => {
    const p = parse(t)!;
    const body = stripPlan(p.c.body);
    const was = stripping();
    setStripping(new Map(was).set(p.c.sha, body));
    return {
      ops: [],
      path: atRepo(p.b.repo, "/outline"),
      body: { branch: p.b.name, head: p.o.head, edits: [{ sha: p.c.sha, subject: p.c.subject, body }] },
      settled: () => view("branch", p.id)?.tip !== p.o.head,
      said: `stripped the plan from ${p.c.short.slice(0, 7)} — u puts it back`,
      failed: `couldn't reword ${p.c.short.slice(0, 7)}`,
      rollback: () => setStripping(was),
      inverse: { id: "words.undo", target: p.id },
    };
  },
});

command({
  id: "words.undo",
  title: "Put a commit message back as it was",
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
      said: "message put back",
      failed: "couldn't put the message back",
    };
  },
});
