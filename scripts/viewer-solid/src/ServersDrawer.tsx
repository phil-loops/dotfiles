// The Servers drawer — the proper home for dev-server previews the Activity dock only teases.
// Polls /previews (health-probed) while open. Three things the dock can't show: real HEALTH
// (healthy/compiling/error/starting, with latency + the compile-error line), the CONNECTIONS
// each preview rides on (its worktree → borrowed main checkout → the ONE shared Docker stack),
// and per-server actions (open · restart · kill · log). The shared stack is surfaced once, with
// the isolation truth stated plainly: every preview and :3000 hit the same DB — writes collide.
//
// Styling: Tailwind utilities against the ledger @theme (the migration's reference surface).
// Health carries all the color: sage = serving, ember = warming, del = broken, faint = gone.
import { createQuery, useQueryClient } from "@tanstack/solid-query";
import { createEffect, createSignal, For, Index, Show } from "solid-js";

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
  jobs?: boolean; // a --jobs worker log exists alongside the web log
  managed?: boolean; // false = a next-dev listener no preview session owns (task dev, leftover headless server)
  pid?: string;
  behind?: string; // commits the served checkout trails origin/main — healthy ≠ fresh
  serves?: string; // the server's own X-Dev-Worktree claim: "<branch>@<sha> <path>" (loops-provenance stamp)
  servesMismatch?: boolean; // header path ≠ the dir this card claims — the port is NOT what it says
};
type Service = { name: string; status: string; up: boolean; state?: string }; // up · done (finished init job) · failed
// project/dir name the compose project that actually holds the ports — often a worktree's, not
// main's (home=false), and a worktree stack carries its own volumes. starting = a start click's
// `compose up` still running; err = that run's last line after it failed.
type SchemaDrift = {
  pg?: { head: string; behind: number; ahead: number; latestBehind: string; latestAhead: string };
  ch?: { head: string; behind: number; latestBehind: string };
};
type Substrate = {
  project: string; dir?: string; home?: boolean; shared: boolean;
  starting?: boolean; err?: string | null; db?: string | null; up: number; total: number; services: Service[];
  schema?: SchemaDrift;
};
type PreviewsResp = { ok: boolean; previews: Preview[]; substrate: Substrate };

// health → label + the state's stripe/badge tint. starting/compiling are transient warmth.
const HEALTH: Record<string, { label: string; stripe: string; badge: string; pulse?: string; card?: string }> = {
  healthy: { label: "healthy", stripe: "border-l-add", badge: "text-add" },
  compiling: { label: "compiling", stripe: "border-l-ember", badge: "text-ember", pulse: "animate-breathe motion-reduce:animate-none" },
  starting: { label: "starting", stripe: "border-l-ember", badge: "text-ember", pulse: "animate-breathe motion-reduce:animate-none" },
  error: { label: "error", stripe: "border-l-del", badge: "font-semibold text-del" },
  wedged: { label: "not responding", stripe: "border-l-del", badge: "font-semibold text-del" },
  probing: { label: "probing…", stripe: "border-l-ink-faint", badge: "text-ink-faint", pulse: "animate-breathe motion-reduce:animate-none" },
  dead: { label: "dead", stripe: "border-l-ink-faint", badge: "text-ink-faint", card: "opacity-65" },
  orphaned: { label: "orphaned", stripe: "border-l-ink-faint", badge: "text-ink-faint", card: "opacity-65" },
};
const FALLBACK = { label: "", stripe: "border-l-ink-faint", badge: "text-ink-dim" };

// button grammar: quiet ghost by default; the danger variant is a card's one destructive act.
const BTN_SHAPE = "cursor-pointer rounded-[7px] border bg-transparent px-[11px] py-[3px] text-[11px] leading-[1.55] tracking-[0.04em] no-underline transition-colors duration-[120ms] disabled:cursor-default disabled:opacity-45";
const BTN = `${BTN_SHAPE} border-rule text-ink-faint enabled:hover:border-ink-faint enabled:hover:text-ink`;
const BTN_DANGER = `${BTN_SHAPE} ml-auto border-del text-del opacity-85 enabled:hover:bg-del-bg enabled:hover:opacity-100`;
const CONN_NODE = "rounded border border-rule bg-vellum-night px-1.5 py-px";

// every loading surface holds the shape it is about to become, so nothing arrives late and
// shoves the list down. Sizes are hand-matched to the real elements they stand in for.
const Skel = (props: { w: string; h?: string; cls?: string }) => (
  <span
    class={`inline-block flex-none animate-breathe rounded-[3px] bg-rule motion-reduce:animate-none ${props.cls ?? ""}`}
    style={{ width: props.w, height: props.h ?? "9px" }}
  />
);
const SKEL_CHIPS = ["46px", "172px", "44px", "96px", "124px", "98px", "132px", "138px", "50px", "54px", "72px"];
const SkelCard = () => (
  <div class="rounded-[10px] border border-rule border-l-[3px] border-l-ink-faint bg-vellum-raise px-[13px] py-[11px]">
    <div class="flex items-center gap-2.5"><Skel w="170px" h="17px" /><Skel w="34px" h="11px" cls="ml-auto" /></div>
    <div class="mt-[7px] flex items-center gap-3"><Skel w="78px" h="13px" /><Skel w="104px" h="13px" /></div>
    <div class="mt-2 flex flex-wrap gap-[5px]"><Skel w="212px" h="19px" /><Skel w="96px" h="19px" /><Skel w="88px" h="19px" /></div>
    <div class="mt-2.5 flex gap-[7px]"><Skel w="62px" h="25px" cls="rounded-[7px]" /><Skel w="44px" h="25px" cls="rounded-[7px]" /><Skel w="44px" h="25px" cls="ml-auto rounded-[7px]" /></div>
  </div>
);
const Spinner = () => <span class="inline-block animate-rs-spin not-italic motion-reduce:animate-none">⟳</span>;

async function post(url: string, body: unknown) {
  await fetch(url, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  }).catch(() => {});
}

const shortSvc = (n: string, project: string) =>
  (project && n.startsWith(project + "-") ? n.slice(project.length + 1) : n.replace(/^loops-/, "")).replace(/-1$/, "");
const shortDir = (d: string) => d.split("/").filter(Boolean).pop() ?? d;
const shortMig = (m: string) => m.replace(/^[0-9]+_?/, "").replace(/\.sql$/, "");

export function ServersDrawer() {
  const qc = useQueryClient();
  // the Activity dock polls /processes ambiently and already knows every preview by the time
  // the drawer opens — seed from its cache so the list paints instantly with health "probing",
  // and the /previews probe fills in real health ~a second later. Same server-side snapshot
  // feeds both endpoints, so the seeded membership can't disagree with the probed one.
  const seedFromDock = (): PreviewsResp | undefined => {
    type DockProc = { kind: string; id: string; label: string; dir?: string; url?: string; status: string; detail: string; age: string };
    const procs = qc.getQueryData<DockProc[]>(["processes"]);
    if (!procs) return undefined;
    return {
      ok: true,
      previews: procs.filter((p) => p.kind === "preview").map((p) => ({
        name: p.id, branch: p.label, dir: p.dir ?? "", url: p.url,
        port: p.detail.startsWith(":") ? p.detail.slice(1) : "",
        state: p.status, age: p.age, health: "probing",
      })),
      substrate: { project: "loops", shared: true, up: 0, total: 0, services: [] },
    };
  };
  const q = createQuery<PreviewsResp>(() => ({
    queryKey: ["previews"],
    queryFn: () => fetch("/previews").then((r) => r.json() as Promise<PreviewsResp>),
    enabled: open(),
    refetchInterval: open() ? 3000 : false,
    placeholderData: seedFromDock,
  }));
  const previews = () => q.data?.previews ?? [];
  // the main server is the one serving the literal main branch (its scratch worktree reports
  // "main" via stack-open intent), wherever it landed — NOT whatever squats :3000.
  const mainSrv = () => previews().find((p) => p.branch === "main");
  const sub = () => (q.isPlaceholderData ? undefined : q.data?.substrate);   // the seed's stub would read "0/0 up"
  // drift renders only when real — schema in sync stays silent (ambient stays quiet)
  const drift = () => {
    const sc = sub()?.schema;
    if (!sc) return null;
    const noisy = (sc.pg && (sc.pg.behind > 0 || sc.pg.ahead > 0)) || (sc.ch && sc.ch.behind > 0);
    return noisy ? sc : null;
  };
  const [busy, setBusy] = createSignal<string | null>(null); // dir (or "__all__") mid-action
  const [logFor, setLogFor] = createSignal<string | null>(null);
  // which stream the pane tails: the web server's, or the --jobs worker's (jobs run there, not in next dev)
  const [logSrc, setLogSrc] = createSignal<"web" | "jobs">("web");
  // the tail follows new output only while the reader is at the bottom — scrolling up to study a
  // line pins the view until they scroll back down. Drawer-level, not per-card: a card that
  // re-renders mid-read must not silently re-arm following.
  let logPinned = true;
  // live tail — next dev keeps appending, so poll while a log pane is open
  const logQ = createQuery<{ log?: string }>(() => ({
    queryKey: ["preview-log", logFor(), logSrc()],
    queryFn: () => fetch("/preview-log?dir=" + encodeURIComponent(logFor() ?? "") + (logSrc() === "jobs" ? "&which=jobs" : "")).then((r) => r.json() as Promise<{ log?: string }>),
    enabled: logFor() != null,
    refetchInterval: logFor() != null ? 1500 : false,
  }));
  const logText = () => (logQ.data ? logQ.data.log?.trim() || "(log empty)" : "loading…");

  // kill carries the port — a dir can host both a registered preview and an unmanaged stray,
  // so only the port names a server precisely
  const act = async (p: Preview, path: string) => {
    setBusy(p.dir + p.port);
    await post(path, { dir: p.dir, port: p.port });
    await q.refetch();
    setBusy(null);
  };
  const [mainPort, setMainPort] = createSignal("3000");
  const launchMain = async () => { setBusy("__main__"); await post("/preview-main", { port: mainPort().trim() }); await q.refetch(); setBusy(null); };
  const reap = async () => { setBusy("__all__"); await post("/preview-reap", {}); await q.refetch(); setBusy(null); };
  const killAll = async () => {
    setBusy("__all__");
    for (const p of previews()) { await post("/preview-kill", { dir: p.dir, port: p.port }); }
    await q.refetch();
    setBusy(null);
  };
  const showLog = (dir: string) => { logPinned = true; setLogSrc("web"); setLogFor(logFor() === dir ? null : dir); };
  const pickSrc = (s: "web" | "jobs") => { logPinned = true; setLogSrc(s); };
  const startStack = async () => { setBusy("__stack__"); await post("/stack-up", { dir: sub()?.dir }); await q.refetch(); setBusy(null); };
  const stackStarting = () => busy() === "__stack__" || !!sub()?.starting;

  return (
    <Show when={open()}>
      <div class="fixed inset-0 z-[209] bg-[rgba(0,0,0,0.45)] backdrop-blur-[2px]" onClick={() => setOpen(false)} />
      <aside
        class="servers-drawer fixed inset-y-0 right-0 z-[210] flex flex-col border-l border-rule bg-[linear-gradient(180deg,var(--color-vellum-raise),var(--color-vellum-night)_340px)] font-mono text-[13px] text-ink shadow-[-24px_0_60px_-18px_rgba(0,0,0,0.8)] transition-[width] duration-200 motion-reduce:transition-none"
        classList={{ "w-[min(460px,92vw)]": logFor() == null, "w-[min(1000px,96vw)]": logFor() != null }}
      >
        <header class="flex items-baseline gap-3 border-b border-rule px-4.5 pt-4 pb-[13px]">
          <span class="font-display text-[19px] font-semibold italic text-ink">Dev servers</span>
          <span class="inline-flex items-center gap-1.5 text-[10px] uppercase tracking-[0.18em] text-ink-faint">
            <Show when={q.data} fallback="probing">{previews().length} running</Show>
            <Show when={!q.data || q.isPlaceholderData}><Spinner /></Show>
          </span>
          <button class="ml-auto cursor-pointer px-0.5 text-[18px] leading-none text-ink-faint hover:text-ink" title="close" onClick={() => setOpen(false)}>×</button>
        </header>

        {/* main — the one server not tied to a branch node. When it's down, a quiet launcher with a
            port preference; when up (task dev or a launch), it lists below with the previews. */}
        <Show when={!q.data || !mainSrv()}>
          <section class="flex flex-wrap items-center gap-x-2.5 gap-y-1.5 border-b border-rule px-4.5 py-[11px]">
            <Show when={q.data} fallback={<><Skel w="92px" h="25px" cls="rounded-[7px]" /><Skel w="72px" h="19px" cls="rounded-[7px]" /><Skel w="100%" h="16px" /></>}>
            <button class={BTN} disabled={busy() === "__main__"} onClick={launchMain}>
              {busy() === "__main__" ? "starting main…" : "▷ run main"}
            </button>
            <label class="flex items-center gap-1 text-[10.5px] text-ink-faint">
              port
              <input
                class="w-[46px] rounded border border-rule bg-vellum-night px-1.5 py-px text-center text-[11px] text-ink-dim focus:border-ink-faint focus:text-ink focus:outline-none"
                value={mainPort()}
                onInput={(e) => setMainPort(e.currentTarget.value)}
                onKeyDown={(e) => { if (e.key === "Enter" && busy() !== "__main__") { launchMain(); } }}
              />
            </label>
            <span class="text-[10.5px] text-ink-faint">main checkout · web only · falls back to a free port if taken</span>
            </Show>
          </section>
        </Show>

        {/* shared substrate — the one Docker stack everything rides; a quiet section, not a card */}
        <section class="border-b border-rule px-4.5 pt-3 pb-[13px]">
          <div class="flex items-center gap-2">
            <Show
              when={sub()}
              fallback={<>
                <span class="h-[7px] w-[7px] flex-none animate-breathe rounded-full bg-ink-faint motion-reduce:animate-none" />
                <span class="flex items-center gap-1.5 text-[12px] text-ink-dim">shared dev stack · <Skel w="48px" /></span>
              </>}
            >
              {(s) => (<>
                <span
                  class="h-[7px] w-[7px] flex-none rounded-full"
                  classList={{
                    "bg-add shadow-[0_0_6px_rgba(143,174,122,0.5)]": s().total > 0 && s().up >= s().total,
                    "animate-breathe bg-ember motion-reduce:animate-none": stackStarting() && s().up < s().total,
                    "bg-del shadow-[0_0_6px_rgba(200,122,85,0.5)]": !stackStarting() && (s().total === 0 || s().up < s().total),
                  }}
                />
                <span class="min-w-0 text-[12px] text-ink-dim">shared dev stack · {s().up}/{s().total} up</span>
                <Show when={s().total === 0 || s().up < s().total}>
                  <button class={`${BTN} ml-auto flex-none whitespace-nowrap`} disabled={stackStarting()} onClick={startStack}>
                    {stackStarting() ? <>starting… <Spinner /></> : "▷ start stack"}
                  </button>
                </Show>
              </>)}
            </Show>
          </div>
          {/* the live stack is whichever compose project holds the ports — often a worktree's, and
              compose scopes volumes per project, so that stack's data is not main's */}
          <Show when={sub()?.home === false && sub()?.dir}>
            <p class="mt-[7px] text-[10.5px] leading-[1.5] text-ember opacity-85">
              running from {shortDir(sub()!.dir!)} — its own Postgres/ClickHouse volumes, not main's
            </p>
          </Show>
          {/* a preview probes HEALTHY against a database with no tables — say so before its first query does */}
          <Show when={sub()?.db === "empty"}>
            <p class="mt-[7px] text-[11px] leading-[1.5] text-del">
              this Postgres has no app schema — every query will fail until <code class="text-ink-dim">task dev:migrate</code> runs
            </p>
          </Show>
          <p class="mt-[7px] mb-[9px] text-[11px] leading-[1.5] text-ember opacity-85">One stack for everything — every preview and :3000 read/write the same DB. Not isolated; concurrent seeds/migrations collide.</p>
          {/* the invisible hazard made visible: a branch migrated (or lagged) the shared DB */}
          <Show when={drift()}>
            {(sc) => (
              <p class="mt-[-3px] mb-[9px] text-[11px] leading-[1.5] text-ember" title={`applied heads — pg: ${sc().pg?.head || "?"} · ch: ${sc().ch?.head || "?"}`}>
                schema drift vs main:
                <Show when={(sc().pg?.behind ?? 0) > 0}>{" "}DB missing {sc().pg!.behind} migration{sc().pg!.behind === 1 ? "" : "s"} ({shortMig(sc().pg!.latestBehind)})</Show>
                <Show when={(sc().pg?.ahead ?? 0) > 0}>{" "}· DB carries {sc().pg!.ahead} not in main ({shortMig(sc().pg!.latestAhead)})</Show>
                <Show when={(sc().ch?.behind ?? 0) > 0}>{" "}· ClickHouse {sc().ch!.behind} behind</Show>
              </p>
            )}
          </Show>
          <Show when={sub()?.err}>
            {(e) => <p class="mt-[-3px] mb-[9px] text-[11px] leading-[1.5] text-del">docker compose up: {e()}</p>}
          </Show>
          <div class="flex flex-wrap gap-1">
            <Show when={sub()} fallback={<For each={SKEL_CHIPS}>{(w) => <Skel w={w} h="21px" cls="rounded-md" />}</For>}>
              {(s) => (
                <For each={s().services}>
                  {(svc) => (
                    <span
                      class="rounded-md border bg-vellum-night px-[7px] py-px text-[10px]"
                      classList={{
                        "border-rule text-ink-dim": svc.up,
                        "border-rule text-ink-faint opacity-70": svc.state === "done",
                        "border-del text-del": !svc.up && svc.state !== "done",
                      }}
                      title={svc.status}
                    >{shortSvc(svc.name, s().project)}{svc.state === "done" ? " · done" : svc.state === "failed" ? " · exited" : ""}</span>
                  )}
                </For>
              )}
            </Show>
          </div>
        </section>

        <Show
          when={previews().length > 0}
          fallback={
            <Show
              when={q.data}
              fallback={<div class="flex flex-auto flex-col gap-2.5 px-4 py-3.5"><SkelCard /><SkelCard /></div>}
            >
              <p class="px-4.5 py-[30px] text-center italic text-ink-faint">No dev servers running. Start one from a node's ⋯ menu → ▷ preview.</p>
            </Show>
          }
        >
          {/* each server is a ledger entry — branch identity first, the left stripe carries health */}
          <div class="flex flex-auto flex-col gap-2.5 overflow-y-auto px-4 py-3.5">
            {/* Index, not For: every 3s poll returns fresh objects (latency alone changes), and
                For would rebuild each card — throwing away the open log's scroll position */}
            <Index each={previews()}>
              {(p) => {
                const h = () => HEALTH[p().health] ?? { ...FALLBACK, label: p().health };
                let logPre: HTMLPreElement | undefined;
                createEffect(() => {
                  logText();
                  if (logFor() === p().dir && logPre && logPinned) { logPre.scrollTop = logPre.scrollHeight; }
                });
                return (
                  <div class={`card rounded-[10px] border border-rule border-l-[3px] bg-vellum-raise px-[13px] py-[11px] transition-[border-color] duration-[250ms] ${h().stripe} ${h().card ?? ""}`}>
                    {/* the branch is the card's identity — the "which server is which" answer */}
                    <div class="flex items-baseline gap-2.5">
                      <span class="truncate text-[13.5px] font-semibold text-ink" title={p().dir}>{p().branch || p().name}</span>
                      <Show when={p().managed === false}>
                        <span class="flex-none rounded border border-ember px-1.5 py-px text-[9px] uppercase tracking-[0.08em] text-ember" title="a next-dev listener no preview session owns — started outside the dock (task dev, leftover headless server)">unmanaged</span>
                      </Show>
                      <span class="ml-auto flex-none text-[11px] text-ink-faint">{p().age}</span>
                    </div>
                    <div class="mt-[5px] flex items-baseline gap-3">
                      <span class={`inline-flex items-baseline gap-1.5 text-[10px] uppercase tracking-[0.06em] ${h().badge}`}>
                        <span class={`h-1.5 w-1.5 flex-none self-center rounded-full bg-current ${h().pulse ?? ""}`} />
                        {h().label}{p().latency != null ? ` · ${p().latency}ms` : ""}
                      </span>
                      <Show when={p().url} fallback={<span class="text-[11px] text-ink-faint">:{p().port}</span>}>
                        <a class="text-[11px] text-patina no-underline hover:text-ink hover:underline" href={p().url} target="_blank" rel="noopener">localhost:{p().port} ↗</a>
                      </Show>
                      <Show when={p().behind && p().behind !== "0"}>
                        <span class="text-[10.5px] text-ember" title="the checkout this server serves trails origin/main — healthy means answering, not fresh">{p().behind} behind main</span>
                      </Show>
                      {/* the server's own claim of what it serves — proof beyond pid archaeology */}
                      <Show when={p().serves}>
                        <span class={p().servesMismatch ? "text-[10.5px] font-semibold text-del" : "text-[10.5px] text-ink-faint"} title={p().serves}>
                          {p().servesMismatch ? `⚠ serves ${p().serves}` : `✓ ${p().serves!.split(" ")[0]}`}
                        </span>
                      </Show>
                    </div>
                    <Show when={p().error}>
                      <div class="mt-[7px] truncate text-[10.5px] text-del" title={p().error}>{p().error}</div>
                    </Show>
                    <div class="mt-2 flex flex-wrap items-center gap-[5px] text-[10px] text-ink-faint" title="each preview runs its own worktree but borrows main's node_modules + .env, and shares the one Docker stack">
                      <span class={CONN_NODE}>⌂ {shortDir(p().dir)}</span>
                      <span>→</span>
                      <Show when={p().managed !== false} fallback={<span class={CONN_NODE}>pid {p().pid}</span>}>
                        <span class={CONN_NODE}>borrows main</span>
                      </Show>
                      <span>→</span>
                      <span class={`${CONN_NODE} text-patina`}>shared stack</span>
                    </div>
                    <div class="mt-2.5 flex items-center gap-[7px]">
                      {/* restart/log only make sense for servers the dock owns — an unmanaged
                          stray has no session to respawn and no log file to tail */}
                      <Show when={p().managed !== false}>
                        <button class={BTN} disabled={busy() === p().dir + p().port} onClick={() => act(p(), "/preview-restart")}>
                          {busy() === p().dir + p().port ? "…" : "restart"}
                        </button>
                        <button class={BTN} onClick={() => showLog(p().dir)}>{logFor() === p().dir ? "hide log" : "log"}</button>
                      </Show>
                      {/* kill stands apart — the one destructive act on the card, in the ledger's del voice */}
                      <button class={BTN_DANGER} disabled={busy() === p().dir + p().port} onClick={() => act(p(), "/preview-kill")}>kill</button>
                    </div>
                    <Show when={logFor() === p().dir}>
                      {/* two streams, one pane — the toggle only exists when a worker actually wrote a log */}
                      <Show when={p().jobs}>
                        <div class="mt-[9px] flex gap-[5px]">
                          <For each={["web", "jobs"] as const}>
                            {(s) => (
                              <button
                                class="cursor-pointer rounded-md border bg-vellum-night px-[7px] py-px text-[10px] transition-colors duration-[120ms]"
                                classList={{
                                  "border-ink-faint text-ink": logSrc() === s,
                                  "border-rule text-ink-faint hover:text-ink": logSrc() !== s,
                                }}
                                onClick={() => pickSrc(s)}
                              >{s === "jobs" ? "jobs worker" : "web"}</button>
                            )}
                          </For>
                        </div>
                      </Show>
                      <pre
                        ref={logPre}
                        onScroll={() => { if (logPre) { logPinned = logPre.scrollHeight - logPre.scrollTop - logPre.clientHeight < 40; } }}
                        class="mt-[9px] h-[min(62vh,600px)] overflow-auto rounded-[7px] border border-rule bg-diff-bg px-3 py-2.5 text-[11.5px] leading-[1.6] whitespace-pre-wrap text-ink-dim"
                      >{logText()}</pre>
                    </Show>
                  </div>
                );
              }}
            </Index>
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
