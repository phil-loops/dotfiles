import type { RestackAmbient, RestackMerges, Project, PR } from "./types";
import type { ViewerLocation } from "./router";
import { leaf } from "./shared";

// A shipping forest's ONE trailing signal: its concrete next step. Ranked so the band
// sorts your-move work (merge / fix / push) above waiting-on-others (CI / review); the
// top your-move row is the "start here". Null → the row falls back to its quiet trail.
export type NextStep = { rank: number; yourMove: boolean; text: string; title: string };

export function nextStep(p: Project, pr: PR | undefined): NextStep | null {
  if (pr && !pr.draft) {
    const blocked = pr.mergeState === "BLOCKED" || pr.mergeState === "DIRTY";
    if (pr.review === "APPROVED" && pr.ci === "passing" && !blocked)
      return { rank: 0, yourMove: true, text: `⬆ merge #${pr.num}`, title: `approved · CI green — ready to land\n${pr.title}` };
    if (pr.ci === "failing")
      return { rank: 1, yourMove: true, text: `↻ fix CI #${pr.num}`, title: `CI failing on the open PR\n${pr.title}` };
    if (pr.review === "CHANGES_REQUESTED")
      return { rank: 1, yourMove: true, text: `✎ address review #${pr.num}`, title: `changes requested\n${pr.title}` };
    if (pr.review === "APPROVED" && blocked)
      return { rank: 1, yourMove: true, text: `⚠ unblock #${pr.num}`, title: `approved, but the merge is blocked (${pr.mergeState})\n${pr.title}` };
    if (pr.ci === "pending")
      return { rank: 5, yourMove: false, text: `⧗ CI #${pr.num}`, title: `checks running — nothing for you yet\n${pr.title}` };
    return { rank: 6, yourMove: false, text: `⧗ review #${pr.num}`, title: `waiting on review — nothing for you yet\n${pr.title}` };
  }
  if (pr) return { rank: 4, yourMove: false, text: `draft #${pr.num}`, title: `draft PR — mark it ready when it is\n${pr.title}` };
  const base = p.candidates?.[0] ?? p.mergeable?.[0];
  if (base) return { rank: 2, yourMove: true, text: `▸ push ${leaf(base)}`, title: `next base ready to push: ${base}` };
  return null;
}

type ChipDescriptor = { cls: string; text: string; title: string; to?: ViewerLocation };

// The Forests-home ambient chip: collapse the daemon's dry-run forest verdict to the single
// most-urgent signal (conflict > merged-ghost > would-restack > clean), with a click-target.
export function ambientChip(
  a: RestackAmbient | undefined,
  forestBranchesData: { branch: string; project?: string }[] | undefined,
): ChipDescriptor | null {
    if (!a?.available || !a.report) return null;
    const s = a.report.summary;
    const stale = (a.age_s ?? 0) > 3600; // daemon hasn't refreshed in >1h → don't trust it
    const age = a.age_s == null ? "" : a.age_s < 90 ? "just now"
      : a.age_s < 3600 ? `${Math.round(a.age_s / 60)}m ago` : `${Math.round(a.age_s / 3600)}h ago`;
    let title = `dry-run @ ${age}: ${s.clean} clean · ${s.would_restack} would-restack · `
      + `${s.would_contract} merged · ${s.will_conflict} will-conflict · ${s.skipped} skipped (moves nothing)`;
    // name the culprits so the alarm is actionable, not just a count
    const conflicts = a.report.branches.filter((b) => b.verdict === "will-conflict");
    if (conflicts.length) {
      title += "\n\nwill conflict:\n" + conflicts
        .map((b) => `  ${b.branch}${b.conflict_pr ? ` → #${b.conflict_pr} ${b.conflict_title ?? ""}` : ""}`)
        .join("\n");
    }
    // in an auto-drop tier the daemon already deletes merged ghosts, so anything still showing
    // is HELD (checked out in a worktree); in dry-run nothing is being dropped, so it's a to-do.
    const autoDrops = a.tier === "contract" || a.tier === "apply";
    const ghosts = a.report.branches.filter((b) => b.verdict === "would-contract");
    if (ghosts.length) {
      title += autoDrops
        ? "\n\nalready merged — the --contract daemon auto-drops these; any still here are held"
          + " (checked out in a worktree). Check out elsewhere, or a forest's ▸ ready button clears them:\n"
          + ghosts.map((b) => `  ${b.branch}`).join("\n")
        : "\n\nalready merged — the daemon isn't auto-dropping (dry-run); a forest's ▸ ready button drops"
          + " these, or reinstall it with `restack-daemon --contract install`:\n"
          + ghosts.map((b) => `  ${b.branch}`).join("\n");
    }
    // route a click to the forest carrying the most actionable branches (or Work when they
    // span several) — the chip surfaces the drift, the forest's ▸ ready button stages the fix.
    const projectOf = (branch: string) => (forestBranchesData || []).find((fb) => fb.branch === branch)?.project;
    const counts = new Map<string, number>();
    for (const b of a.report.branches) {
      if (b.verdict !== "will-conflict" && b.verdict !== "would-restack" && b.verdict !== "would-contract") continue;
      const p = projectOf(b.branch);
      if (p) counts.set(p, (counts.get(p) ?? 0) + 1);
    }
    const to: ViewerLocation | undefined = counts.size === 1
      ? { kind: "forest", name: [...counts.keys()][0] }
      : counts.size > 1 ? { kind: "home", tab: "work" } : undefined;
    if (stale) return { cls: "amb-stale", text: "✦ daemon idle", title };
    if (s.will_conflict > 0) return { cls: "amb-conflict", text: `⚠ ${s.will_conflict} will conflict`, title, to };
    if (s.would_contract > 0) {
      const text = autoDrops ? `⊘ ${s.would_contract} merged — held` : `⊘ ${s.would_contract} merged — drop?`;
      return { cls: "amb-contract", text, title, to };
    }
    if (s.would_restack > 0) return { cls: "amb-restack", text: `⟳ ${s.would_restack} would restack`, title, to };
    return { cls: "amb-clean", text: "✦ forest clean", title };
}

// What just landed on main (the daemon's merge attribution) → gold + PR numbers when any is
// YOURS, pointing at the next base to push; a dim count otherwise; gone after a day.
export function landedChip(
  m: RestackMerges | undefined,
  projectsData: Project[] | undefined,
): ChipDescriptor | null {
    if (!m?.available || !m.prs?.length) return null;
    if ((m.age_s ?? Infinity) > 24 * 3600) return null; // yesterday's news isn't "just" landed
    const age = m.age_s == null ? "" : m.age_s < 90 ? "just now"
      : m.age_s < 3600 ? `${Math.round(m.age_s / 60)}m ago` : `${Math.round(m.age_s / 3600)}h ago`;
    const mine = m.prs.filter((p) => p.mine === true);
    const nums = mine.map((p) => `#${p.number}`).join(" ");
    const title = m.prs
      .map((p) => `#${p.number} ${p.title ?? ""}${p.mine ? " — yours" : p.author ? ` — ${p.author}` : ""}`)
      .join("\n") + (m.direct ? `\n+ ${m.direct} direct push(es)` : "") + `\n\nlanded ${age}`;
    if (mine.length) {
      // the daemon's --apply pass has already contracted these merged branches and restacked +
      // prepped the survivors, so the chip's job shifts from "what landed" to "what's next": each
      // landed PR maps to its forest via the merge fact, and that forest's first mergeable base is
      // the just-prepped next-to-push — link straight to it.
      const nextForest = mine
        .map((p) => (projectsData || []).find((f) => f.merged && (f.merged.pr === p.number || f.merged.branch === p.branch)))
        .find((f) => f?.candidates?.length);
      const base = nextForest?.candidates?.[0];
      if (base && nextForest) {
        return {
          cls: "landed-mine",
          text: `⛳ ${nums} landed — next ▸ ${leaf(base)}`,
          title: `${title}\n\nadvanced: forest restacked onto fresh main; next base ${base} prepped for push`,
          to: { kind: "forest", name: nextForest.name, node: base },
        };
      }
      return { cls: "landed-mine", text: `⛳ ${nums} landed — yours`, title };
    }
    return { cls: "landed-other", text: `⛳ ${m.prs.length} landed ${age}`, title };
}
