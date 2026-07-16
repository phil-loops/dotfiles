// The Servers drawer — the proper home for dev-server previews the Activity dock only teases.
// Polls /previews (health-probed) while open. Three things the dock can't show: real HEALTH
// (healthy/compiling/error/starting, with latency + the compile-error line), the CONNECTIONS
// each preview rides on (its worktree → borrowed main checkout → the ONE shared Docker stack),
// and per-server actions (open · restart · kill · log). The shared stack is surfaced once, with
// the isolation truth stated plainly: every preview and :3000 hit the same DB — writes collide.
//
// Styling: Tailwind utilities against the ledger @theme (the migration's reference surface).
// Health carries all the color: sage = serving, ember = warming, del = broken, faint = gone.
import { createQuery } from "@tanstack/solid-query";
import { createSignal, For, Show } from "solid-js";

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

// health → label + the state's stripe/badge tint. starting/compiling are transient warmth.
const HEALTH: Record<string, { label: string; stripe: string; badge: string; pulse?: string; card?: string }> = {
  healthy: { label: "healthy", stripe: "border-l-add", badge: "text-add" },
  compiling: { label: "compiling", stripe: "border-l-ember", badge: "text-ember", pulse: "animate-breathe motion-reduce:animate-none" },
  starting: { label: "starting", stripe: "border-l-ember", badge: "text-ember", pulse: "animate-breathe motion-reduce:animate-none" },
  error: { label: "error", stripe: "border-l-del", badge: "font-semibold text-del" },
  wedged: { label: "not responding", stripe: "border-l-del", badge: "font-semibold text-del" },
  dead: { label: "dead", stripe: "border-l-ink-faint", badge: "text-ink-faint", card: "opacity-65" },
  orphaned: { label: "orphaned", stripe: "border-l-ink-faint", badge: "text-ink-faint", card: "opacity-65" },
};
const FALLBACK = { label: "", stripe: "border-l-ink-faint", badge: "text-ink-dim" };

// button grammar: quiet ghost by default; the danger variant is a card's one destructive act.
const BTN_SHAPE = "cursor-pointer rounded-[7px] border bg-transparent px-[11px] py-[3px] text-[11px] leading-[1.55] tracking-[0.04em] no-underline transition-colors duration-[120ms] disabled:cursor-default disabled:opacity-45";
const BTN = `${BTN_SHAPE} border-rule text-ink-faint enabled:hover:border-ink-faint enabled:hover:text-ink`;
const BTN_DANGER = `${BTN_SHAPE} ml-auto border-del text-del opacity-85 enabled:hover:bg-del-bg enabled:hover:opacity-100`;
const CONN_NODE = "rounded border border-rule bg-vellum-night px-1.5 py-px";

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
      <div class="fixed inset-0 z-[209] bg-[rgba(0,0,0,0.45)] backdrop-blur-[2px]" onClick={() => setOpen(false)} />
      <aside class="servers-drawer fixed inset-y-0 right-0 z-[210] flex w-[min(460px,92vw)] flex-col border-l border-rule bg-[linear-gradient(180deg,var(--color-vellum-raise),var(--color-vellum-night)_340px)] font-mono text-[13px] text-ink shadow-[-24px_0_60px_-18px_rgba(0,0,0,0.8)]">
        <header class="flex items-baseline gap-3 border-b border-rule px-4.5 pt-4 pb-[13px]">
          <span class="font-display text-[19px] font-semibold italic text-ink">Dev servers</span>
          <span class="text-[10px] uppercase tracking-[0.18em] text-ink-faint">{previews().length} running</span>
          <button class="ml-auto cursor-pointer px-0.5 text-[18px] leading-none text-ink-faint hover:text-ink" title="close" onClick={() => setOpen(false)}>×</button>
        </header>

        {/* shared substrate — the one Docker stack everything rides; a quiet section, not a card */}
        <Show when={sub()}>
          {(s) => (
            <section class="border-b border-rule px-4.5 pt-3 pb-[13px]">
              <div class="flex items-center gap-2">
                <span
                  class="h-[7px] w-[7px] flex-none rounded-full"
                  classList={{
                    "bg-add shadow-[0_0_6px_rgba(143,174,122,0.5)]": s().total > 0 && s().up >= s().total,
                    "bg-del shadow-[0_0_6px_rgba(200,122,85,0.5)]": s().total === 0 || s().up < s().total,
                  }}
                />
                <span class="text-[12px] text-ink-dim">shared dev stack · {s().up}/{s().total} up</span>
              </div>
              <p class="mt-[7px] mb-[9px] text-[11px] leading-[1.5] text-ember opacity-85">One stack for everything — every preview and :3000 read/write the same DB. Not isolated; concurrent seeds/migrations collide.</p>
              <div class="flex flex-wrap gap-1">
                <For each={s().services}>
                  {(svc) => (
                    <span
                      class="rounded-md border bg-vellum-night px-[7px] py-px text-[10px]"
                      classList={{ "border-rule text-ink-dim": svc.up, "border-del text-del": !svc.up }}
                      title={svc.status}
                    >{shortSvc(svc.name)}</span>
                  )}
                </For>
              </div>
            </section>
          )}
        </Show>

        <Show
          when={previews().length > 0}
          fallback={<p class="px-4.5 py-[30px] text-center italic text-ink-faint">No dev servers running. Start one from a node's ⋯ menu → ▷ preview.</p>}
        >
          {/* each server is a ledger entry — branch identity first, the left stripe carries health */}
          <div class="flex flex-auto flex-col gap-2.5 overflow-y-auto px-4 py-3.5">
            <For each={previews()}>
              {(p) => {
                const h = () => HEALTH[p.health] ?? { ...FALLBACK, label: p.health };
                return (
                  <div class={`card rounded-[10px] border border-rule border-l-[3px] bg-vellum-raise px-[13px] py-[11px] transition-[border-color] duration-[250ms] ${h().stripe} ${h().card ?? ""}`}>
                    {/* the branch is the card's identity — the "which server is which" answer */}
                    <div class="flex items-baseline gap-2.5">
                      <span class="truncate text-[13.5px] font-semibold text-ink" title={p.dir}>{p.branch || p.name}</span>
                      <span class="ml-auto flex-none text-[11px] text-ink-faint">{p.age}</span>
                    </div>
                    <div class="mt-[5px] flex items-baseline gap-3">
                      <span class={`inline-flex items-baseline gap-1.5 text-[10px] uppercase tracking-[0.06em] ${h().badge}`}>
                        <span class={`h-1.5 w-1.5 flex-none self-center rounded-full bg-current ${h().pulse ?? ""}`} />
                        {h().label}{p.latency != null ? ` · ${p.latency}ms` : ""}
                      </span>
                      <Show when={p.url} fallback={<span class="text-[11px] text-ink-faint">:{p.port}</span>}>
                        <a class="text-[11px] text-patina no-underline hover:text-ink hover:underline" href={p.url} target="_blank" rel="noopener">localhost:{p.port} ↗</a>
                      </Show>
                    </div>
                    <Show when={p.error}>
                      <div class="mt-[7px] truncate text-[10.5px] text-del" title={p.error}>{p.error}</div>
                    </Show>
                    <div class="mt-2 flex flex-wrap items-center gap-[5px] text-[10px] text-ink-faint" title="each preview runs its own worktree but borrows main's node_modules + .env, and shares the one Docker stack">
                      <span class={CONN_NODE}>⌂ {shortDir(p.dir)}</span>
                      <span>→</span>
                      <span class={CONN_NODE}>borrows main</span>
                      <span>→</span>
                      <span class={`${CONN_NODE} text-patina`}>shared stack</span>
                    </div>
                    <div class="mt-2.5 flex items-center gap-[7px]">
                      <button class={BTN} disabled={busy() === p.dir} onClick={() => act(p.dir, "/preview-restart")}>
                        {busy() === p.dir ? "…" : "restart"}
                      </button>
                      <button class={BTN} onClick={() => showLog(p.dir)}>{logFor() === p.dir ? "hide log" : "log"}</button>
                      {/* kill stands apart — the one destructive act on the card, in the ledger's del voice */}
                      <button class={BTN_DANGER} disabled={busy() === p.dir} onClick={() => act(p.dir, "/preview-kill")}>kill</button>
                    </div>
                    <Show when={logFor() === p.dir}>
                      <pre class="mt-[9px] max-h-[220px] overflow-auto rounded-[7px] border border-rule bg-diff-bg px-2.5 py-[9px] text-[10px] leading-[1.5] whitespace-pre-wrap text-ink-dim">{logText()}</pre>
                    </Show>
                  </div>
                );
              }}
            </For>
          </div>
        </Show>

        <footer class="flex items-center gap-2 border-t border-rule px-4 py-[11px]">
          <button class={BTN} disabled={busy() === "__all__"} onClick={reap}>reap orphaned</button>
          <button class={BTN_DANGER} disabled={busy() === "__all__" || previews().length === 0} onClick={killAll}>kill all</button>
        </footer>
      </aside>
    </Show>
  );
}
