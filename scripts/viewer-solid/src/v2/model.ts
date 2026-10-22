// Derived views over the store, shared by the surfaces and the commands that move through them.
import { createMemo, createRoot } from "solid-js";
import { list } from "./store";
import type { Project } from "./types";
import { cursor, cursorIdx, showArchive } from "./ui";

const byName = (a: Project, b: Project) => a.name.localeCompare(b.name) || a.repo.localeCompare(b.repo);

export const model = createRoot(() => {
  const projects = createMemo(() => {
    const all = list("project");
    return {
      focus: all.filter((p) => p.state === "focus").sort((a, b) => (a.rank ?? 0) - (b.rank ?? 0) || byName(a, b)),
      workbench: all.filter((p) => p.state === "workbench").sort(byName),
      archive: all.filter((p) => p.state === "archive").sort(byName),
    };
  });
  /** The rows the cursor moves through, top to bottom. */
  const rows = createMemo(() => {
    const p = projects();
    return [...p.focus, ...p.workbench, ...(showArchive() ? p.archive : [])].map((x) => x.id);
  });
  /** The selected row: the cursor's project while it's visible, else whatever now sits in its
   *  place — so archiving a row leaves the cursor on the next one, ready for the next `x`. */
  const selected = createMemo(() => {
    const r = rows();
    const id = cursor();
    if (id && r.includes(id)) return id;
    return r[Math.min(cursorIdx(), r.length - 1)];
  });
  return { projects, rows, selected };
});
