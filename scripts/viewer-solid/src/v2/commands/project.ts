// Moving a forest between focus, the workbench and the archive (POST /project-state).
import { command, type Write } from "../registry";
import { list, view, world } from "../store";
import type { ProjectState } from "../types";

const LABEL: Record<ProjectState, string> = { focus: "focus", workbench: "the workbench", archive: "the archive" };
const KEY: Record<ProjectState, string> = { focus: "f", workbench: "w", archive: "x" };

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
      said: state === "archive" ? `archived ${p.name} — u puts it back` : undefined,
      failed: `couldn't move ${p.name} to ${LABEL[state]}`,
      inverse: { id: `project.${p.state}`, target: id },
    };
  };
}

for (const state of ["focus", "workbench", "archive"] as ProjectState[]) {
  command({
    id: `project.${state}`,
    title: `Move to ${LABEL[state]}`,
    scope: "project",
    budget: "config-write",
    keys: [KEY[state]],
    v1: [`key:${KEY[state]}`],
    available: (id) => !!id && !!view("project", id),
    write: moveTo(state),
  });
}
