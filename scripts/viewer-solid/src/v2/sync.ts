// The store's sync layer and the app's only door to the server: the /state snapshot, the
// /v2/events patch stream (reconnect + resync), GET reads, and the POST transport the runner
// sends writes through. Every request carries X-Request-Id, which the server writes into its
// request log, so a client timing joins the server's.
import { applyPatch, hydrate, setConn, world } from "./store";
import { ACTOR, PAGE_LOAD, count } from "./telemetry";
import type { Patch, Snapshot } from "./types";

let seq = 0;
export const nextRid = () => `${PAGE_LOAD}-${++seq}`;

const headers = (rid: string, extra?: Record<string, string>) => ({ "X-Stack-Actor": ACTOR, "X-Request-Id": rid, ...extra });

export async function getJSON<T>(path: string): Promise<T> {
  const r = await fetch(path, { headers: headers(nextRid()) });
  if (!r.ok) throw new Error(`${path} → ${r.status}`);
  return (await r.json()) as T;
}

export interface Sent {
  ok: boolean;
  outcome: "ok" | "refused" | "failed";
  err?: string;
  rid: string;
  body?: Record<string, unknown>;
}

/** POST a write. A 200 {ok:false} is a refusal (the server's reason rides in X-Stack-Refused). */
export async function post(path: string, body: unknown): Promise<Sent> {
  const rid = nextRid();
  const t0 = performance.now();
  try {
    const r = await fetch(path, {
      method: "POST",
      headers: headers(rid, { "Content-Type": "application/json" }),
      body: JSON.stringify(body),
    });
    const data = (await r.json().catch(() => ({}))) as Record<string, unknown>;
    count("post", performance.now() - t0);
    if (r.ok && data.ok !== false) return { ok: true, outcome: "ok", rid, body: data };
    const err = r.headers.get("X-Stack-Refused") || (r.ok ? "refused" : `http-${r.status}`);
    return { ok: false, outcome: r.ok || r.status < 500 ? "refused" : "failed", err, rid, body: data };
  } catch {
    return { ok: false, outcome: "failed", err: "network", rid };
  }
}

// ── the live store ─────────────────────────────────────────────────────────

let es: EventSource | null = null;
let backoff = 500;
let retry: number | undefined;

async function load(): Promise<void> {
  const t0 = performance.now();
  const s = await getJSON<Snapshot>("/state");
  hydrate(s);
  count("state", performance.now() - t0);
}

function open(): void {
  const v = world.versions;
  es = new EventSource(`/v2/events?epoch=${encodeURIComponent(world.epoch)}&git=${v.git}&remote=${v.remote}`);
  es.addEventListener("hello", () => {
    backoff = 500;
    setConn("live");
  });
  es.addEventListener("patch", (e) => {
    const res = applyPatch(JSON.parse((e as MessageEvent).data) as Patch);
    count(res === "ok" ? "patch" : `patch-${res}`);
    if (res === "gap") void resync();
  });
  es.addEventListener("resync", () => void resync());
  es.onerror = () => {
    close();
    setConn("down");
    count("reconnect");
    retry = window.setTimeout(() => void start(), backoff);
    backoff = Math.min(backoff * 2, 10_000);
  };
}

function close(): void {
  es?.close();
  es = null;
  clearTimeout(retry);
}

async function resync(): Promise<void> {
  count("resync");
  close();
  await start(true);
}

/** Hydrate (first time, or when told to resync), then hold the patch stream open. */
async function start(refetch = false): Promise<void> {
  try {
    if (refetch || !world.ready) await load();
    open();
  } catch {
    setConn("down");
    retry = window.setTimeout(() => void start(refetch), backoff);
    backoff = Math.min(backoff * 2, 10_000);
  }
}

/** Connect the store. A hidden tab drops its stream (browsers cap connections per origin) and
 *  reconnects with its versions on return, catching up from the server's patch ring. */
export function connect(): void {
  void start();
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") close();
    else if (!es) void start();
  });
}
