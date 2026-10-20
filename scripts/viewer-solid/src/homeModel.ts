import type { Project, PR } from "./types";
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
  const landed = p.mergedNodes ?? [];
  if (landed.length)
    return { rank: 2, yourMove: true, text: `⟳ restack — ${leaf(landed[0])} landed`,
      title: `${landed.map((b) => `${b} is already in main`).join("\n")}\n\n`
        + "restack contracts the merged node(s) and rebases the rest onto fresh main" };
  const base = p.candidates?.[0] ?? p.mergeable?.filter((b) => !landed.includes(b))[0];
  if (base) return { rank: 2, yourMove: true, text: `▸ push ${leaf(base)}`, title: `next base ready to push: ${base}` };
  return null;
}
