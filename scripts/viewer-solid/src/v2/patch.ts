// Pure patch logic, shared by the store and its tests.
import type { Entities, EntityType, Patch, Versions } from "./types";

export const emptyEntities = (): Entities => ({ repo: {}, project: {}, branch: {}, pr: {}, landed: {}, conv: {}, thread: {}, draft: {}, todo: {} });

export const TYPES = Object.keys(emptyEntities()) as EntityType[];

/** Each domain's versions advance by exactly one; anything else is a gap (resync) or a replay. */
export function checkVersion(have: Versions, p: Patch): "ok" | "gap" | "stale" {
  const cur = have[p.domain] ?? 0;
  if (p.version <= cur) return "stale";
  return p.version === cur + 1 ? "ok" : "gap";
}

export function applyPatchTo(ents: Entities, p: Patch): void {
  for (const t of TYPES) {
    const table = ents[t] as Record<string, unknown>;
    for (const id of p.deletes[t] ?? []) delete table[id];
    for (const [id, obj] of Object.entries(p.upserts[t] ?? {})) table[id] = obj;
  }
}
