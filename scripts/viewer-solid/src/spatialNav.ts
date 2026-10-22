export type Dir = "up" | "down" | "left" | "right";
export type Point = { x: number; y: number };

// Arrow keys over the map: the nearest node lying in the pressed direction. Off-axis distance
// costs more sideways than vertically — map rows are far apart and indentation is shallow, so a
// down-press should take the next row even when it sits a few columns left, never skip it.
export function nearestInDirection(points: Record<string, Point>, from: string, dir: Dir): string | null {
  const a = points[from];
  if (!a) return null;
  const vertical = dir === "up" || dir === "down";
  const sign = dir === "down" || dir === "right" ? 1 : -1;
  let best: string | null = null;
  let bestScore = Infinity;
  for (const [id, b] of Object.entries(points)) {
    if (id === from) continue;
    const along = sign * (vertical ? b.y - a.y : b.x - a.x);
    if (along <= 1) continue;
    const across = Math.abs(vertical ? b.x - a.x : b.y - a.y);
    const score = along + across * (vertical ? 0.5 : 2);
    if (score < bestScore) {
      bestScore = score;
      best = id;
    }
  }
  return best;
}
