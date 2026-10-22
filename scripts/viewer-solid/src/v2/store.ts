// The one local store of the world: normalized entities hydrated from /state and patched from
// /v2/events (sync.ts drives both), plus the optimistic overlay the runner layers on top. Views
// read through `view()` / `list()`, so an optimistic change and a server patch look the same.
import { batch } from "solid-js";
import { createStore, produce, reconcile } from "solid-js/store";
import { applyPatchTo, checkVersion, emptyEntities } from "./patch";
import type { Entities, EntityType, Patch, Snapshot, Versions } from "./types";

export type Conn = "connecting" | "live" | "down";

interface World {
  ready: boolean;
  epoch: string;
  versions: Versions;
  entities: Entities;
  conn: Conn;
}

const [world, setWorld] = createStore<World>({
  ready: false,
  epoch: "",
  versions: { git: 0, remote: 0 },
  entities: emptyEntities(),
  conn: "connecting",
});
export { world };

/** One pending optimistic change: these fields of this entity, until the runner drops it. */
export interface Op {
  seq: number;
  type: EntityType;
  id: string;
  fields: Record<string, unknown>;
}

const [overlay, setOverlay] = createStore<{ ops: Op[] }>({ ops: [] });

const listeners = new Set<() => void>();
/** Called after every hydrate or patch — the runner reconciles pending commands here. */
export function onChange(fn: () => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
const changed = () => listeners.forEach((fn) => fn());

export function hydrate(s: Snapshot): void {
  const ents = { ...emptyEntities(), ...s.entities } as Entities;
  batch(() => {
    setWorld("entities", reconcile(ents));
    setWorld({ epoch: s.epoch, versions: { ...s.versions }, ready: true });
  });
  changed();
}

/** Apply a server patch; "gap" or "stale" means it wasn't applied (gap → resync). */
export function applyPatch(p: Patch): "ok" | "gap" | "stale" {
  const v = checkVersion(world.versions, p);
  if (v !== "ok") return v;
  setWorld(
    produce((w) => {
      applyPatchTo(w.entities, p);
      w.versions[p.domain] = p.version;
    }),
  );
  changed();
  return "ok";
}

export const setConn = (c: Conn) => setWorld("conn", c);

export function addOps(ops: Op[]): void {
  setOverlay("ops", (cur) => [...cur, ...ops]);
}

export function dropOps(seq: number): void {
  setOverlay("ops", (cur) => cur.filter((o) => o.seq !== seq));
}

/** The entity as the user should see it: the server's copy with pending changes on top. */
export function view<T extends EntityType>(type: T, id: string): Entities[T][string] | undefined {
  const base = world.entities[type][id] as Entities[T][string] | undefined;
  const ops = overlay.ops.filter((o) => o.type === type && o.id === id);
  if (!base || !ops.length) return base;
  return Object.assign({}, base, ...ops.map((o) => o.fields)) as Entities[T][string];
}

export function list<T extends EntityType>(type: T): Entities[T][string][] {
  return Object.keys(world.entities[type]).map((id) => view(type, id)!) as Entities[T][string][];
}
