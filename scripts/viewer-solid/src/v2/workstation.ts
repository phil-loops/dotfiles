// The machine: the dev servers this workstation runs, the one shared substrate (the Docker stack)
// they all ride, and what the tooling costs the box (srv/preview.py, /footprint). Not store
// entities — read while the page is open, refreshed when the pulse's procs signal says a preview
// moved; the footprint and an open log have no signal, so those two poll.
import { createMemo, createRoot, createSignal } from "solid-js";
import { nudge } from "./store";
import { getJSON, onProcs } from "./sync";

export interface Server {
  name: string;
  port: string;
  dir: string;
  branch?: string;
  url?: string;
  state: string;
  age: string;
  health: string;
  latency?: number;
  error?: string;
  /** a --jobs worker log exists beside the web log */
  jobs?: boolean;
  /** false: a next-dev listener no preview session owns (task dev, a leftover headless server) */
  managed?: boolean;
  pid?: string;
  /** commits the served checkout trails origin/main */
  behind?: string;
  /** the server's own X-Dev-Worktree claim: "<branch>@<sha> <path>" */
  serves?: string;
  servesMismatch?: boolean;
  /** the natural "before" for a swap: its stack parent, else main */
  swapTo?: string;
}
export interface Service {
  name: string;
  status: string;
  up: boolean;
  state?: string;
}
export interface SchemaDrift {
  pg?: { head: string; behind: number; ahead: number; latestBehind: string; latestAhead: string };
  ch?: { head: string; behind: number; latestBehind: string };
}
export interface Substrate {
  project: string;
  dir?: string;
  home?: boolean;
  shared: boolean;
  starting?: boolean;
  err?: string | null;
  db?: string | null;
  up: number;
  total: number;
  services: Service[];
  schema?: SchemaDrift;
  doctor?: { checks: { name: string; detail: string }[]; ok: boolean; broken: { name: string; detail: string }[] } | null;
}
export interface Footprint {
  machine: {
    totalMb: number;
    pressure: "ok" | "high" | "critical";
    levelPct: number;
    freeMb: number;
    activeMb: number;
    inactiveMb: number;
    wiredMb: number;
    compressedMb: number;
    swap: { totalMb: number; usedMb: number };
    top: { rssMb: number; pid: number; cpu: number; name: string }[];
  };
  repo: {
    worktrees: number;
    scratch: number;
    nodeModulesClones: number;
    disk: { usedGb?: number; totalGb?: number; pct?: number };
    hygiene?: { at: number; days: number; stripped: number; apparentMb: number; kept: number } | null;
  };
  server: { pid: number; rssMb: number; threads: number; children: number; uptimeS: number; caches: Record<string, number> };
}

/** A server's id on the page: its port names it exactly (one dir can host a preview and a stray). */
export const sid = (s: Server) => s.port || s.dir;
export const mkey = (id: string) => `m:${id}`;

export const machine = createRoot(() => {
  const [read, setRead] = createSignal<{ servers: Server[]; substrate: Substrate } | undefined>();
  const [footprint, setFootprint] = createSignal<Footprint | undefined>();
  const servers = createMemo(() => read()?.servers ?? []);
  const substrate = () => read()?.substrate;
  const server = (id: string | undefined) => (id ? servers().find((s) => sid(s) === id) : undefined);
  /** the server for the literal main branch, wherever it landed — not whatever squats :3000 */
  const main = () => servers().find((s) => s.branch === "main");

  const [logFor, setLogFor] = createSignal<string | undefined>();
  const [logSrc, setLogSrc] = createSignal<"web" | "jobs">("web");
  const [log, setLog] = createSignal<string | undefined>();
  const [mainPort, setMainPort] = createSignal("3000");
  /** what a swapped port served before, so it can swing back */
  const [swapped, setSwapped] = createSignal<Record<string, { dir: string; label: string }>>({});

  let reading: Promise<void> | null = null;
  let again = false;
  /** Re-read the servers; a call while one is out queues exactly one more. */
  function refresh(): void {
    if (reading) {
      again = true;
      return;
    }
    reading = getJSON<{ previews: Server[]; substrate: Substrate }>("/previews")
      .then((r) => {
        setRead({ servers: r.previews ?? [], substrate: r.substrate });
        nudge();
      })
      .catch(() => {})
      .finally(() => {
        reading = null;
        if (again) {
          again = false;
          refresh();
        }
      });
  }
  const measure = () => void getJSON<Footprint>("/footprint").then(setFootprint, () => {});
  const tail = () => {
    const id = logFor();
    const src = logSrc();
    const s = server(id);
    if (!s) return;
    void getJSON<{ log?: string }>(`/preview-log?dir=${encodeURIComponent(s.dir)}${src === "jobs" ? "&which=jobs" : ""}`).then(
      (r) => {
        if (logFor() === id && logSrc() === src) setLog(r.log?.trim() || "(log empty)");
      },
      () => {},
    );
  };
  const showLog = (id: string | undefined, src: "web" | "jobs" = "web") => {
    setLog(undefined);
    setLogSrc(src);
    setLogFor(id);
    tail();
  };

  /** Hold the page live: read now, follow the procs signal, poll the footprint and an open log. */
  function watch(): () => void {
    refresh();
    measure();
    const off = onProcs(refresh);
    const fp = window.setInterval(measure, 15_000);
    const lg = window.setInterval(tail, 1_500);
    return () => {
      off();
      clearInterval(fp);
      clearInterval(lg);
    };
  }

  return { servers, substrate, server, main, footprint, refresh, watch, logFor, logSrc, log, showLog, mainPort, setMainPort, swapped, setSwapped };
});

const shortMig = (m: string) => m.replace(/^[0-9]+_?/, "").replace(/\.sql$/, "");
/** The shared DB's drift from main in words, or "" when it's in step. */
export function drift(sc: SchemaDrift | undefined): string {
  const bits: string[] = [];
  if (sc?.pg && sc.pg.behind > 0) bits.push(`missing ${sc.pg.behind} migration${sc.pg.behind === 1 ? "" : "s"} (${shortMig(sc.pg.latestBehind)})`);
  if (sc?.pg && sc.pg.ahead > 0) bits.push(`${sc.pg.ahead} not in main (${shortMig(sc.pg.latestAhead)})`);
  if (sc?.ch && sc.ch.behind > 0) bits.push(`clickhouse ${sc.ch.behind} behind`);
  return bits.join(" · ");
}
