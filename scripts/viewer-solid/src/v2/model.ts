// Derived views over the store, shared by the surfaces and the commands that move through them.
import { createMemo, createRoot } from "solid-js";
import { routeArg, surface } from "./router";
import { baseFor, isClosed, stand, type Stand } from "./ship";
import { list, view, world } from "./store";
import type { Branch, Pr, Project } from "./types";
import { queue } from "./tracker";
import type { Scope } from "./registry";
import { cursor, cursorIdx, expanded, forestFace, now, readyOnly, showArchive } from "./ui";
import { page } from "./review/page";

export interface BranchView {
  b: Branch;
  pr?: Pr;
  st: Stand;
  /** the compare form's base: the parent while it's unlanded, else trunk */
  base: string;
}

export interface ForestView {
  p: Project;
  branches: BranchView[];
  ready: BranchView[];
  /** branches with no PR yet — what a launch pushes and opens */
  unopened: BranchView[];
  onGitHub: number;
  closed: boolean;
}

const byName = (a: Project, b: Project) => a.name.localeCompare(b.name) || a.repo.localeCompare(b.repo);
export const pkey = (id: string) => `p:${id}`;
export const bkey = (id: string) => `b:${id}`;
export const tkey = (id: string) => `t:${id}`;
/** a landed chapter of a forest's story — its branch is gone, so it's keyed by the landed PR */
export const dkey = (id: string) => `d:${id}`;

export const model = createRoot(() => {
  const projects = createMemo(() => {
    const all = list("project");
    return {
      focus: all.filter((p) => p.state === "focus").sort((a, b) => (a.rank ?? 0) - (b.rank ?? 0) || byName(a, b)),
      workbench: all.filter((p) => p.state === "workbench").sort(byName),
      archive: all.filter((p) => p.state === "archive").sort(byName),
    };
  });

  const forests = createMemo(() => {
    const t = now();
    const prs = world.entities.pr;
    const groups = new Map<string, Branch[]>();
    for (const b of list("branch")) (groups.get(b.project) ?? groups.set(b.project, []).get(b.project)!).push(b);
    const out = new Map<string, ForestView>();
    for (const p of list("project")) {
      const bs = (groups.get(p.id) ?? []).sort((a, b) => a.order - b.order || a.name.localeCompare(b.name));
      const trunk = world.entities.repo[p.repo]?.main ?? "main";
      const seen = new Map<string, BranchView>();
      const viewOf = (b: Branch, depth = 0): BranchView => {
        const hit = seen.get(b.id);
        if (hit) return hit;
        const pb = b.parentId && depth < 64 ? view("branch", b.parentId) : undefined;
        const pv = pb ? viewOf(pb, depth + 1) : undefined;
        const parent = pv ? { ship: pv.st.ship, pr: pv.pr, name: pv.b.name } : undefined;
        const pr = prs[b.id] as Pr | undefined;
        const v: BranchView = { b, pr, st: stand(b, pr, parent, t), base: baseFor(b, parent, trunk) };
        seen.set(b.id, v);
        return v;
      };
      const branches = bs.map((b) => viewOf(b));
      const live = branches.filter((v) => v.st.ship !== "landed");
      out.set(p.id, {
        p,
        branches,
        ready: branches.filter((v) => v.st.ready),
        unopened: live.filter((v) => !v.pr),
        onGitHub: branches.filter((v) => v.pr).length,
        closed: isClosed(branches.map((v) => v.st.ship)),
      });
    }
    return out;
  });

  const todos = createMemo(() => queue(list("todo")));

  /** A forest's merged PRs, oldest first — its story's opening chapters. */
  const landedOf = (pid: string) => list("landed").filter((l) => l.project === pid).sort((a, b) => a.at.localeCompare(b.at));

  /** The forest a /v2/p/<repo>/<project> page shows. */
  const pageProject = createMemo(() => {
    if (surface().id !== "forest") return undefined;
    const a = routeArg();
    const cut = a.indexOf("/");
    const id = cut > 0 ? `${a.slice(0, cut)}:${a.slice(cut + 1)}` : "";
    return view("project", id) ? id : undefined;
  });

  /** The rows the cursor moves through, top to bottom: forests and the branches of open ones, or
   *  on the tracker its items. */
  const rows = createMemo(() => {
    if (surface().id === "todo") return todos().flatMap((s) => s.items.map((t) => tkey(t.id)));
    if (surface().id === "forest") {
      const pid = pageProject();
      if (!pid) return [];
      const bs = forests().get(pid)?.branches ?? [];
      if (forestFace() === "branches") return bs.map((v) => bkey(v.b.id));
      // the story's order: landed, then in flight, then what's left (Story.tsx draws the same)
      const live = bs.filter((v) => v.st.ship !== "landed");
      const flying = (v: BranchView) => !!v.pr || v.b.pushed !== "local";
      return [...landedOf(pid).map((l) => dkey(l.id)), ...live.filter(flying).map((v) => bkey(v.b.id)), ...live.filter((v) => !flying(v)).map((v) => bkey(v.b.id))];
    }
    const p = projects();
    const f = forests();
    const out: string[] = [];
    if (readyOnly()) {
      for (const x of [...p.focus, ...p.workbench]) {
        const ready = f.get(x.id)?.ready ?? [];
        if (!ready.length) continue;
        out.push(pkey(x.id), ...ready.map((v) => bkey(v.b.id)));
      }
      return out;
    }
    const open = expanded();
    for (const x of [...p.focus, ...p.workbench, ...(showArchive() ? p.archive : [])]) {
      out.push(pkey(x.id));
      if (open.has(x.id)) out.push(...(f.get(x.id)?.branches ?? []).map((v) => bkey(v.b.id)));
    }
    return out;
  });

  /** The selected row: the cursor's while it's visible, else whatever now sits in its place — so
   *  archiving a row leaves the cursor on the next one, ready for the next `x`. */
  const selected = createMemo(() => {
    const r = rows();
    const id = cursor();
    if (id && r.includes(id)) return id;
    return r[Math.min(cursorIdx(), r.length - 1)];
  });

  const selectedBranch = createMemo(() => {
    const k = selected();
    return k?.startsWith("b:") ? k.slice(2) : undefined;
  });
  const selectedProject = createMemo(() => {
    const k = selected();
    if (k?.startsWith("p:")) return k.slice(2);
    if (surface().id === "forest") return pageProject();
    const b = selectedBranch();
    return b ? view("branch", b)?.project : undefined;
  });

  const branchView = (id: string): BranchView | undefined => {
    const b = view("branch", id);
    return b ? forests().get(b.project)?.branches.find((v) => v.b.id === id) : undefined;
  };

  const selectedItem = createMemo(() => {
    const k = selected();
    return k?.startsWith("t:") ? k.slice(2) : undefined;
  });

  return { projects, forests, todos, pageProject, landedOf, rows, selected, selectedBranch, selectedProject, selectedItem, branchView };
});

/** What a command of this scope acts on, from the cursor. */
export function targetFor(scope: Scope): string | undefined {
  switch (scope) {
    case "project":
      return model.selectedProject();
    case "branch":
      return model.selectedBranch();
    case "row":
      return model.selected();
    case "item":
      return model.selectedItem();
    case "review":
      return page.id() || undefined;
    case "line":
    case "thread":
    case "pending":
    case "gap": {
      const h = page.here();
      return h && h.kind === scope ? (h.kind === "line" || h.kind === "gap" ? h.key : h.id) : undefined;
    }
    default:
      return undefined;
  }
}

/** The scopes live right now, narrowest first — the keymap breaks ties with this order. */
export function liveScopes(): string[] {
  const out: string[] = [];
  if (surface().id === "forests") {
    if (model.selectedBranch()) out.push("branch");
    if (model.selectedProject()) out.push("project");
    if (model.selected()) out.push("row");
  }
  if (surface().id === "todo" && model.selectedItem()) out.push("item");
  if (surface().id === "forest") {
    if (model.selectedBranch()) out.push("branch", "row");
    out.push("forest");
    if (model.pageProject()) out.push("project");
    out.push("global");
    return out;
  }
  if (surface().id === "review" && !page.overlay()) {
    // on Commits, j/k move through the list until l opens a commit's diff, then through its lines
    if (page.tab() === "commits" && page.historyOpen() && page.historyFocus() === "list") out.push("history");
    else {
      const h = page.here();
      if (h && h.kind !== "file" && h.kind !== "card") out.push(h.kind);
      if (page.historyOpen()) out.push("commit");
    }
  }
  out.push(surface().id, "global");
  return out;
}

const repos = (): string[] => (window as unknown as { __VIEWER_REPOS__?: string[] }).__VIEWER_REPOS__ ?? [];
/** A repo-pinned server path: the server reads the repo from the leading segment. */
export const atRepo = (repo: string, path: string) => (repos().includes(repo) ? `/${encodeURIComponent(repo)}${path}` : path);

export const compareUrl = (v: BranchView) =>
  atRepo(v.b.repo, `/packet-compare?branch=${encodeURIComponent(v.b.name)}&base=${encodeURIComponent(v.base)}`);

/** v1's branch page (the v2 review page is reviewPath in router.ts). */
export const branchPage = (b: Branch) => {
  const project = view("project", b.project)?.name ?? "";
  const repo = repos().includes(b.repo) && b.repo !== "loops" ? `${b.repo}/` : "";
  return `/forests/${repo}${encodeURIComponent(project)}/${b.name}`;
};
