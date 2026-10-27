// Forests: moving one between focus, the workbench and the archive (POST /project-state),
// ordering the focus lane (POST /focus), opening a forest into its spine, the ready filter, launch.
import { startDrag } from "../drag";
import { checkIntegration, integratable } from "../integrate";
import { BASE, forestPath, integrationRef, navigate, reviewPath, surface } from "../router";
import { atRepo, bkey, model, pkey } from "../model";
import { command, type Write } from "../registry";
import { list, view, world } from "../store";
import type { ProjectState } from "../types";
import {
  expanded,
  launching,
  readyOnly,
  setArmed,
  setCursor,
  setCursorIdx,
  setExpanded,
  setLaunching,
  setReadyOnly,
  setForestFace,
  forestFace,
  setWordsOpen,
  setShowArchive,
  toggleIn,
} from "../ui";

const LABEL: Record<ProjectState, string> = { focus: "focus", workbench: "the workbench", archive: "the archive" };
const KEY: Record<ProjectState, string> = { focus: "f", workbench: "w", archive: "X" };
const V1_KEY: Record<ProjectState, string> = { focus: "f", workbench: "w", archive: "x" };

function moveTo(state: ProjectState) {
  return (id: string): Write | null => {
    const p = view("project", id);
    if (!p || p.state === state) return null;
    const top = Math.max(0, ...list("project").filter((q) => q.state === "focus").map((q) => q.rank ?? 0));
    return {
      ops: [{ type: "project", id, fields: { state, rank: state === "focus" ? top + 1 : null } }],
      path: "/project-state",
      body: { repo: p.repo, project: p.name, state },
      settled: () => world.entities.project[id]?.state === state,
      said: state === "archive" ? `archived ${p.name} · u undoes` : p.state === "archive" ? `restored ${p.name}` : undefined,
      failed: `couldn't move ${p.name} to ${LABEL[state]}`,
      inverse: { id: `project.${p.state}`, target: id },
    };
  };
}

const exists = (id: string | undefined) => !!id && !!view("project", id);

for (const state of ["focus", "workbench", "archive"] as ProjectState[]) {
  command({
    id: `project.${state}`,
    label: state === "workbench" ? "bench" : state,
    title: `Move to ${LABEL[state]}`,
    scope: "project",
    budget: "config-write",
    keys: [KEY[state]],
    v1: [`key:${V1_KEY[state]}`],
    available: (id) => exists(id) && view("project", id!)!.state !== state,
    write: moveTo(state),
  });
}

command({
  id: "project.restore",
  title: "Restore from the archive",
  scope: "project",
  budget: "config-write",
  available: (id) => exists(id) && view("project", id!)!.state === "archive",
  write: moveTo("workbench"),
});

// ── the whole forest at once: does it merge, run it, read it ──

command({
  id: "forest.integrate",
  label: "merges?",
  title: "Check the whole forest merges onto main",
  scope: "project",
  budget: "local",
  available: integratable,
  local: (id) => void checkIntegration(id!, true),
});
command({
  id: "forest.preview",
  label: "preview",
  title: "Preview the whole forest — every branch merged, on a side port, opened once it answers",
  scope: "project",
  budget: "local",
  keys: ["g p"],
  v1: ["click:build this project's integration"],
  available: integratable,
  local: (id) => {
    const p = view("project", id!)!;
    window.open(`${atRepo(p.repo, "/preview-wait")}?project=${encodeURIComponent(p.name)}`, "_blank", "noopener");
  },
});
command({
  id: "forest.integration",
  label: "whole diff",
  title: "Read the whole forest's diff against main",
  scope: "project",
  budget: "local",
  keys: ["space i"],
  available: integratable,
  local: (id, e) => {
    const p = view("project", id!)!;
    navigate(reviewPath(p.repo, integrationRef(p.name)), e);
  },
});

// ── the focus lane's order ──

const focusIds = () => model.projects().focus.map((p) => p.id);

/** Rewrite the lane's ranks 1..N with `id` at position `to`. */
function reorder(id: string, to: number): Write | null {
  const order = focusIds();
  const from = order.indexOf(id);
  to = Math.max(0, Math.min(order.length - 1, to));
  if (from < 0 || from === to) return null;
  order.splice(to, 0, ...order.splice(from, 1));
  setCursor(pkey(id));
  const name = view("project", id)!.name;
  return {
    ops: order.map((pid, i) => ({ type: "project" as const, id: pid, fields: { rank: i + 1 } })),
    path: "/focus",
    body: { order: order.map((pid) => ({ repo: view("project", pid)!.repo, project: view("project", pid)!.name })) },
    settled: () => order.every((pid, i) => world.entities.project[pid]?.rank === i + 1),
    failed: `couldn't reorder ${name}`,
    inverse: { id: "focus.move", target: id, arg: from },
  };
}

const inFocus = (id: string | undefined) => !!id && view("project", id)?.state === "focus";

command({
  id: "focus.up",
  label: "move", pair: "focus.down",
  title: "Move up the focus lane",
  scope: "project",
  budget: "config-write",
  keys: ["C-k"],
  available: inFocus,
  write: (id) => reorder(id, focusIds().indexOf(id) - 1),
});
command({
  id: "focus.down",
  label: "move",
  title: "Move down the focus lane",
  scope: "project",
  budget: "config-write",
  keys: ["C-j"],
  available: inFocus,
  write: (id) => reorder(id, focusIds().indexOf(id) + 1),
});
command({
  id: "focus.move",
  title: "Put a forest at a place in the focus lane",
  scope: "project",
  budget: "config-write",
  quiet: true,
  available: inFocus,
  write: (id, to) => (typeof to === "number" ? reorder(id, to) : null),
});
command({
  id: "focus.drag",
  title: "Drag a forest along the focus lane",
  scope: "project",
  budget: "local",
  quiet: true,
  available: inFocus,
  local: (id, e) => {
    setCursor(pkey(id!));
    startDrag(id!, focusIds().indexOf(id!), e as PointerEvent);
  },
});

// ── opening a forest into its spine ──

const hasBranches = (id: string | undefined) => !!id && !!model.forests().get(id)?.branches.length;

command({
  id: "forest.expand",
  label: "open",
  title: "Show the forest's branches",
  scope: "project",
  budget: "local",
  keys: ["l", "right"],
  available: (id) => hasBranches(id) && !expanded().has(id!) && !readyOnly(),
  local: (id) => setExpanded((s) => toggleIn(s, id!, true)),
});
command({
  id: "forest.collapse",
  label: "fold",
  title: "Hide the forest's branches",
  scope: "project",
  budget: "local",
  keys: ["h", "left"],
  available: (id) => !!id && expanded().has(id) && !readyOnly(),
  local: (id) => {
    setCursor(pkey(id!));
    setArmed(undefined);
    setExpanded((s) => toggleIn(s, id!, false));
    if (launching() === id) setLaunching(undefined);
  },
});
command({
  id: "forest.toggle",
  title: "Open or fold the forest",
  scope: "project",
  budget: "local",
  quiet: true,
  available: (id) => hasBranches(id) && !readyOnly(),
  local: (id) => {
    if (expanded().has(id!)) setLaunching((l) => (l === id ? undefined : l));
    setExpanded((s) => toggleIn(s, id!));
  },
});

/** ↵: the selected row's one primary action. */
command({
  id: "row.primary",
  label: "go",
  title: "Do the row's thing",
  scope: "row",
  budget: "local",
  keys: ["ret"],
  quiet: true,
  route: () => {
    const b = model.selectedBranch();
    if (b) {
      const v = model.branchView(b);
      return !v ? null : v.st.action === "push" ? "branch.push" : v.st.action === "pr" ? "branch.pr" : "branch.open";
    }
    const id = model.selectedProject();
    const p = id ? view("project", id) : undefined;
    if (!p) return null;
    if (p.state === "archive") return "project.restore";
    if (model.forests().get(p.id)?.closed) return "project.archive";
    return "forest.page";
  },
});

command({
  id: "forest.page",
  title: "Open the forest's page",
  scope: "project",
  budget: "local",
  available: exists,
  local: (id, e) => {
    const p = view("project", id!)!;
    setCursor(undefined);
    setCursorIdx(0);
    navigate(forestPath(p.repo, p.name), e);
  },
});
command({
  id: "forest.words",
  label: "words",
  title: "Show the branch's commits in full",
  scope: "branch",
  budget: "local",
  keys: ["e"],
  available: (id) => surface().id === "forest" && !!id,
  local: (id) => setWordsOpen((s) => toggleIn(s, id!)),
});
command({
  id: "forest.face",
  label: "story",
  title: "Switch between the story and the branches",
  scope: "forest",
  budget: "local",
  keys: ["tab"],
  local: () => {
    setForestFace(forestFace() === "story" ? "branches" : "story");
    setCursor(undefined);
    setCursorIdx(0);
  },
});
command({
  id: "story.why",
  label: "why",
  title: "Show why a landed chapter happened",
  scope: "forest",
  budget: "local",
  keys: ["e"],
  available: () => forestFace() === "story" && !!model.selected()?.startsWith("d:"),
  local: () => {
    const k = model.selected()!;
    setWordsOpen((s) => toggleIn(s, k));
  },
});
/** The forest page's branches that wait on Phil (push, open the PR, merge), in merge order. */
const readyHere = () => (model.pageProject() ? model.forests().get(model.pageProject()!)?.ready ?? [] : []);
command({
  id: "forest.next.ready",
  label: "next ready",
  title: "Go to the next branch ready for you",
  scope: "forest",
  budget: "local",
  keys: ["space n"],
  available: () => forestFace() === "branches" && readyHere().length > 0,
  local: () => {
    const rs = readyHere();
    const at = rs.findIndex((v) => bkey(v.b.id) === model.selected());
    setCursor(bkey(rs[(at + 1) % rs.length].b.id));
  },
});
command({
  id: "forest.words.all",
  label: "all words",
  title: "Show or hide every branch's commits in full",
  scope: "forest",
  budget: "local",
  keys: ["space e"],
  available: () => forestFace() === "branches" && !!model.pageProject(),
  local: () => {
    const ids = (model.forests().get(model.pageProject()!)?.branches ?? []).map((v) => v.b.id);
    setWordsOpen((s) => (ids.every((id) => s.has(id)) ? new Set([...s].filter((x) => !ids.includes(x))) : new Set([...s, ...ids])));
  },
});
command({
  id: "forest.leave",
  label: "back",
  title: "Go back to Forests",
  scope: "forest",
  budget: "local",
  keys: ["h", "left"],
  local: (_t, e) => navigate(BASE, e),
});

command({
  id: "ready.toggle",
  label: "ready",
  title: "Show only what's ready for you",
  scope: "forests",
  budget: "local",
  keys: ["space r"],
  v1: ["nav:outbox"],
  local: () => {
    setArmed(undefined);
    setReadyOnly((v) => !v);
  },
});

command({
  id: "archive.toggle",
  label: "archive",
  title: "Show or hide the archive",
  scope: "forests",
  budget: "local",
  keys: ["space a"],
  available: () => !readyOnly(),
  local: () => setShowArchive((v) => !v),
});

command({
  id: "forest.launch",
  label: "launch",
  title: "Launch the whole forest",
  scope: "project",
  budget: "local",
  keys: ["L", "space l"],
  v1: ["launch"],
  available: (id) => !!id && (model.forests().get(id)?.unopened.length ?? 0) > 0,
  local: (id) => {
    setReadyOnly(false);
    setExpanded((s) => toggleIn(s, id!, true));
    setLaunching(id);
    const first = model.forests().get(id!)!.unopened[0];
    setCursor(bkey(first.b.id));
  },
});
