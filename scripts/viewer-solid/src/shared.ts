import type { ForestModel, SpineNode, FileDiff } from "./types";

export const leaf = (s?: string): string => (s || "").split("/").pop() ?? "";

// Relative age of a merge, or null once it's older than a week (don't badge stale merges).
export const mergedAgo = (iso?: string): string | null => {
  const t = iso ? Date.parse(iso) : NaN;
  if (!t) return null;
  const s = Math.max(0, (Date.now() - t) / 1000);
  if (s > 7 * 86400) return null;
  if (s < 90) return "just now";
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
};

export const isBlessed = (f: FileDiff): boolean => f.status === "clean";

// compact interest indicator: ▲ per level, capped at 5 with a trailing + (exact n on hover).
export function interestPips(n: number): string {
  if (!n || n <= 0) return "";
  return "▲".repeat(Math.min(n, 5)) + (n > 5 ? "+" : "");
}

export function flattenForest(model: ForestModel | undefined): SpineNode[] {
  if (!model) return [];
  const nodes = model.nodes;
  if (nodes) {
    const out: SpineNode[] = [];
    const seen = new Set<string>();
    const walk = (b: string, d: number) => {
      if (seen.has(b)) return;
      seen.add(b);
      const n = nodes[b];
      if (!n) return;
      out.push({ ...n, id: b, depth: d });
      (n.children || []).forEach((c) => walk(c, d + 1));
    };
    (model.roots || []).forEach((r) => walk(r, 0));
    Object.keys(nodes).forEach((b) => !seen.has(b) && walk(b, 0));
    return out;
  }
  return (model.links || []).map(
    (l) => ({ ...l, id: l.branch, depth: 0 }) as unknown as SpineNode
  );
}
