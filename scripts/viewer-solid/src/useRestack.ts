import { createSignal, createEffect, onCleanup } from "solid-js";
import { createQuery } from "@tanstack/solid-query";
import { provider } from "./provider";
import { setDeleteMode } from "./deleteMode";
import type { Parked, Project } from "./types";

// The Forests-home restack state machine: two-click arm → run in the background → poll status →
// parked-on-conflict hands to Claude. Also owns delete-mode drops. Fed the projects/prs queries
// (data + refetch) so it can read what's behind and refresh after a run.
export function useRestack(deps: {
  projectsData: () => Project[] | undefined;
  refetchProjects: () => void;
  refetchPrs: () => void;
}) {
  const [running, setRunning] = createSignal<string | null>(null); // project (or "__all__") restacking now
  const [parked, setParked] = createSignal<Parked | null>(null); // set on a conflict
  const [restackErr, setRestackErr] = createSignal<string | null>(null);
  const [flash, setFlash] = createSignal<string | null>(null);
  let flashT: ReturnType<typeof setTimeout>;
  const note = (m: string) => {
    setFlash(m);
    clearTimeout(flashT);
    flashT = setTimeout(() => setFlash(null), 2400);
  };
  const [menu, setMenu] = createSignal<string | null>(null); // project whose parked-action popover is open
  const post = (url: string, body: unknown): Promise<{ ok?: boolean; err?: string }> =>
    fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).then((r) => r.json());
  // Restack-all's unit is "had work land", not "trails main": a forest is only behind
  // because main moved, and those rebase on their own when you next touch them. A merged
  // node is the case that WON'T resolve itself — it lingers, advertising a push for work
  // already in main, until the pre-pass contracts it.
  const mergedNames = () =>
    (deps.projectsData() || []).filter((p) => (p.mergedNodes?.length ?? 0) > 0).map((p) => p.name);
  const start = (key: string) => {
    setRestackErr(null);
    // restack-all clears any pre-existing park first (server frees the worktree, then the
    // resilient walk restacks the rest); a single-project restack never auto-drops a park.
    const body =
      key === "__all__"
        ? { projects: mergedNames(), abortParked: !!parked() }
        : { project: key };
    post(key === "__all__" ? "/restack-all" : "/restack", body).then((r) => {
      if (r.ok) {
        setParked(null);
        setRunning(key);
      } else {
        // Don't swallow it — a stale park 409s here; surface why + refresh so the parked
        // branch's contextual button appears on its row.
        setRestackErr(r.err ?? "couldn’t start restack");
        homeStatus.refetch();
      }
    });
  };
  const abort = (project: string) =>
    post("/restack-abort", { project }).then((r) => {
      if (r.ok) {
        setParked(null);
        setRestackErr(null);
        setMenu(null);
        deps.refetchProjects();
        homeStatus.refetch();
      } else {
        setRestackErr(r.err ?? "couldn’t abort");
      }
    });
  // ── delete mode: forget an old forest grouping (config only; branches kept) ──
  const [dropping, setDropping] = createSignal<string | null>(null);
  const dropProject = (project: string) => {
    setDropping(project);
    post("/drop-project", { project }).then((r) => {
      setDropping(null);
      if (r.ok) {
        deps.refetchProjects();
        deps.refetchPrs();
      } else {
        setRestackErr(r.err ?? "couldn’t drop forest");
      }
    });
  };
  onCleanup(() => setDeleteMode(false)); // leaving home always exits delete mode
  const status = createQuery(() => ({
    queryKey: ["restack-status", running()],
    queryFn: () =>
      provider.restackStatus(
        running() && running() !== "__all__" ? running()! : undefined
      ),
    enabled: !!running(),
    refetchInterval: (q) => (q.state.data?.running === false ? false : 2500),
  }));
  createEffect(() => {
    if (!running()) return;
    const d = status.data;
    if (!d || d.running) return; // still churning through the topo walk
    if (d.paused)
      setParked({ project: d.project ?? "", current: d.current ?? "", reason: d.reason ?? "" });
    setRunning(null);
    deps.refetchProjects();
  });
  const resolve = (project: string) =>
    post("/restack-resolve", { project }).then((r) => {
      if (r.ok) {
        setParked(null);
        setMenu(null);
        setRunning(project); // re-poll while Claude resolves + resumes
      }
    });
  // Surface a parked conflict on the home screen even when nothing is running — without
  // this a stale park silently 409s every restack with no clue which branch is stuck.
  const homeStatus = createQuery(() => ({
    queryKey: ["home-restack-status"],
    queryFn: () => provider.restackStatus(),
    refetchInterval: 5000,
  }));
  createEffect(() => {
    if (running()) return; // the running-restack effect owns `parked` mid-walk
    const d = homeStatus.data;
    if (!d) return;
    setParked(
      d.paused ? { project: d.project ?? "", current: d.current ?? "", reason: d.reason ?? "" } : null
    );
  });
  // Live walk progress (done/total/current) for whatever chip started the run — the
  // status poll already carries it; without this the chip freezes at "restacking…".
  const progress = () => (running() ? status.data ?? null : null);
  return { running, parked, restackErr, flash, menu, setMenu, dropping, start, abort, resolve, dropProject, mergedNames, progress };
}
