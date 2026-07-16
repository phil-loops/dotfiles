// The Servers drawer — the proper home for dev-server previews the Activity dock only teases.
// Polls /previews (health-probed) while open. Three things the dock can't show: real HEALTH
// (healthy/compiling/error/starting, with latency + the compile-error line), the CONNECTIONS
// each preview rides on (its worktree → borrowed main checkout → the ONE shared Docker stack),
// and per-server actions (open · restart · kill · log). The shared stack is surfaced once, with
// the isolation truth stated plainly: every preview and :3000 hit the same DB — writes collide.
import { createQuery } from "@tanstack/solid-query";
import { createSignal, For, Show } from "solid-js";
import "./ServersDrawer.css";

const [open, setOpen] = createSignal(false);
export const openServers = () => setOpen(true);
export const serversOpen = open;

type Preview = {
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
  borrows?: string;
  log?: string;
};
type Service = { name: string; status: string; up: boolean };
type Substrate = { project: string; shared: boolean; up: number; total: number; services: Service[] };
type PreviewsResp = { ok: boolean; previews: Preview[]; substrate: Substrate };

// health → (label, css class). starting/compiling are transient "warm" states, not failures.
const HEALTH: Record<string, { label: string; cls: string }> = {
  healthy: { label: "healthy", cls: "ok" },
  compiling: { label: "compiling", cls: "warm" },
  starting: { label: "starting", cls: "warm" },
  error: { label: "error", cls: "bad" },
  wedged: { label: "not responding", cls: "bad" },
  dead: { label: "dead", cls: "dead" },
  orphaned: { label: "orphaned", cls: "dead" },
};

async function post(url: string, body: unknown) {
  await fetch(url, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  }).catch(() => {});
}

const shortSvc = (n: string) => n.replace(/^loops-/, "").replace(/-1$/, "");
const shortDir = (d: string) => d.split("/").filter(Boolean).pop() ?? d;

export function ServersDrawer() {
  const q = createQuery<PreviewsResp>(() => ({
    queryKey: ["previews"],
    queryFn: () => fetch("/previews").then((r) => r.json() as Promise<PreviewsResp>),
    enabled: open(),
    refetchInterval: open() ? 3000 : false,
  }));
  const previews = () => q.data?.previews ?? [];
  const sub = () => q.data?.substrate;
  const [busy, setBusy] = createSignal<string | null>(null); // dir (or "__all__") mid-action
  const [logFor, setLogFor] = createSignal<string | null>(null);
  const [logText, setLogText] = createSignal("");

  const act = async (dir: string, path: string) => {
    setBusy(dir);
    await post(path, { dir });
    await q.refetch();
    setBusy(null);
  };
  const reap = async () => { setBusy("__all__"); await post("/preview-reap", {}); await q.refetch(); setBusy(null); };
  const killAll = async () => {
    setBusy("__all__");
    for (const p of previews()) { await post("/preview-kill", { dir: p.dir }); }
    await q.refetch();
    setBusy(null);
  };
  const showLog = async (dir: string) => {
    if (logFor() === dir) { setLogFor(null); return; }
    setLogFor(dir);
    setLogText("loading…");
    const r = await fetch("/preview-log?dir=" + encodeURIComponent(dir))
      .then((res) => res.json() as Promise<{ log?: string }>)
      .catch(() => ({ log: "" }));
    setLogText(r.log?.trim() || "(log empty)");
  };

  return (
    <Show when={open()}>
      <div class="servers-backdrop" onClick={() => setOpen(false)} />
      <aside class="servers-drawer">
        <header class="servers-head">
          <span class="title">Dev servers</span>
          <span class="sub">{previews().length} running</span>
          <button class="x" title="close" onClick={() => setOpen(false)}>×</button>
        </header>

        <Show when={sub()}>
          {(s) => (
            <section class="substrate" classList={{ down: s().total === 0 || s().up < s().total }}>
              <div class="sub-head">
                <span class="dot" />
                <span class="sub-title">shared dev stack · {s().up}/{s().total} up</span>
              </div>
              <p class="sub-warn">One stack for everything — every preview and :3000 read/write the same DB. Not isolated; concurrent seeds/migrations collide.</p>
              <div class="sub-svcs">
                <For each={s().services}>
                  {(svc) => <span class="svc" classList={{ down: !svc.up }} title={svc.status}>{shortSvc(svc.name)}</span>}
                </For>
              </div>
            </section>
          )}
        </Show>

        <Show
          when={previews().length > 0}
          fallback={<p class="empty">No dev servers running. Start one from a node's ⋯ menu → ▷ preview.</p>}
        >
          <div class="cards">
            <For each={previews()}>
              {(p) => {
                const h = () => HEALTH[p.health] ?? { label: p.health, cls: "" };
                return (
                  <div class="card" classList={{ [h().cls]: true }}>
                    <div class="card-top">
                      <span class="badge" classList={{ [h().cls]: true }}>
                        {h().label}{p.latency != null ? ` · ${p.latency}ms` : ""}
                      </span>
                      <Show when={p.url} fallback={<span class="branch">{p.branch || p.name}</span>}>
                        <a class="branch" href={p.url} target="_blank" rel="noopener">{p.branch || p.name}</a>
                      </Show>
                      <span class="port">:{p.port}</span>
                      <span class="age">{p.age}</span>
                    </div>
                    <Show when={p.error}>
                      <div class="err" title={p.error}>{p.error}</div>
                    </Show>
                    <div class="conns" title="each preview runs its own worktree but borrows main's node_modules + .env, and shares the one Docker stack">
                      <span class="node">⌂ {shortDir(p.dir)}</span>
                      <span class="arrow">→</span>
                      <span class="node">borrows main</span>
                      <span class="arrow">→</span>
                      <span class="node shared">shared stack</span>
                    </div>
                    <div class="actions">
                      <Show when={p.url}>
                        <a class="btn" href={p.url} target="_blank" rel="noopener">open</a>
                      </Show>
                      <button class="btn" disabled={busy() === p.dir} onClick={() => act(p.dir, "/preview-restart")}>
                        {busy() === p.dir ? "…" : "restart"}
                      </button>
                      <button class="btn" disabled={busy() === p.dir} onClick={() => act(p.dir, "/preview-kill")}>kill</button>
                      <button class="btn" onClick={() => showLog(p.dir)}>{logFor() === p.dir ? "hide log" : "log"}</button>
                    </div>
                    <Show when={logFor() === p.dir}>
                      <pre class="log">{logText()}</pre>
                    </Show>
                  </div>
                );
              }}
            </For>
          </div>
        </Show>

        <footer class="servers-foot">
          <button class="btn" disabled={busy() === "__all__"} onClick={reap}>reap orphaned</button>
          <button class="btn" disabled={busy() === "__all__" || previews().length === 0} onClick={killAll}>kill all</button>
        </footer>
      </aside>
    </Show>
  );
}
