// The Machine — the workstation's dev resources as one first-class page: every server
// that's serving, the ONE shared substrate they all ride, and the levers (run · swap ·
// restart · kill). Replaces the Servers drawer, whose only opener was an Activity-dock row
// that existed while previews ran — "nothing is running" was an unnavigable state instead
// of an invitation. Route: /machine, always reachable from the rail.
//
// Layout thesis — the bus: one patina line down the left gutter; every server taps into
// it, and it terminates in the substrate block spanning the page's full width. N servers,
// one substrate — the geometry states the sharing the drawer used to explain in prose.
//
// Styling: Tailwind utilities against the ledger @theme; the bus itself is machine-*
// classes in index.css (pseudo-element plumbing utilities can't express inline).
import { createQuery, useQueryClient } from "@tanstack/solid-query";
import { createEffect, createSignal, For, Index, Show } from "solid-js";

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
  swapTo?: string; // the natural "before" for this branch: its stack parent, else main
};
type Service = { name: string; status: string; up: boolean; state?: string }; // up · done (finished init job) · failed
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
const driftBits = (sc: SchemaDrift) => {
  const bits: string[] = [];
  if (sc.pg && sc.pg.behind > 0) { bits.push(`DB missing ${sc.pg.behind} migration${sc.pg.behind === 1 ? "" : "s"} (${shortMig(sc.pg.latestBehind)})`); }
  if (sc.pg && sc.pg.ahead > 0) { bits.push(`DB carries ${sc.pg.ahead} not in main (${shortMig(sc.pg.latestAhead)})`); }
  if (sc.ch && sc.ch.behind > 0) { bits.push(`ClickHouse ${sc.ch.behind} behind`); }
  return bits.join(" · ");
};

export function MachinePage() {
  const qc = useQueryClient();
  // the Activity dock polls /processes ambiently and already knows every preview — seed from
  // its cache so the page paints instantly with health "probing", and the /previews probe
  // fills in real health ~a second later.
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
    refetchInterval: 3000,
    placeholderData: seedFromDock,
  }));
  const previews = () => q.data?.previews ?? [];
  // the main server is the one serving the literal main branch, wherever it landed — NOT
  // whatever squats :3000.
  const mainSrv = () => previews().find((p) => p.branch === "main");
  const sub = () => (q.isPlaceholderData ? undefined : q.data?.substrate);   // the seed's stub would read "0/0 up"
  // drift renders in ember only when real; when everything is in step the same line affirms
  // it quietly — on a resources page "current" is information, not noise.
  const drift = () => {
    const sc = sub()?.schema;
    if (!sc) return null;
    const noisy = (sc.pg && (sc.pg.behind > 0 || sc.pg.ahead > 0)) || (sc.ch && sc.ch.behind > 0);
    return noisy ? sc : null;
  };
  const inStep = () => {
    const sc = sub()?.schema;
    return !!sc?.pg && sc.pg.behind === 0 && sc.pg.ahead === 0 && (!sc.ch || sc.ch.behind === 0);
  };
  const [busy, setBusy] = createSignal<string | null>(null); // dir+port (or "__all__") mid-action
  const [logFor, setLogFor] = createSignal<string | null>(null);
  const [logSrc, setLogSrc] = createSignal<"web" | "jobs">("web");
  // the tail follows new output only while the reader is at the bottom — scrolling up pins
  // the view until they scroll back down. Page-level, not per-card: a card that re-renders
  // mid-read must not silently re-arm following.
  let logPinned = true;
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
  // before/after on one port: remember what a swapped card used to serve so it can swing back
  const [swapPrev, setSwapPrev] = createSignal<Record<string, { dir: string; label: string }>>({});
  const doSwap = async (p: Preview, target: { branch?: string; dir?: string }, remember: boolean) => {
    setBusy(p.dir + p.port);
    const prev = { ...swapPrev() };
    if (remember) { prev[p.port] = { dir: p.dir, label: p.branch || p.name }; } else { delete prev[p.port]; }
    await post("/preview-swap", { port: p.port, ...target });
    setSwapPrev(prev);
    await q.refetch();
    setBusy(null);
  };
  const showLog = (dir: string) => { logPinned = true; setLogSrc("web"); setLogFor(logFor() === dir ? null : dir); };
  const pickSrc = (s: "web" | "jobs") => { logPinned = true; setLogSrc(s); };
  const startStack = async () => { setBusy("__stack__"); await post("/stack-up", { dir: sub()?.dir }); await q.refetch(); setBusy(null); };
  const stackStarting = () => busy() === "__stack__" || !!sub()?.starting;

  return (
    <div class="machine-page mx-auto min-w-0 max-w-[860px] px-8 py-8 font-mono text-[13px] text-ink max-[640px]:px-4">
      <header class="mb-7 border-b border-rule pb-4">
        <div class="mb-1 font-mono text-[10px] tracking-[0.14em] uppercase text-ink-faint">this workstation</div>
        <div class="flex flex-wrap items-baseline gap-x-4 gap-y-1">
          <h1 class="m-0 font-display text-[27px] italic leading-tight text-ink">The Machine</h1>
          <span class="inline-flex items-center gap-1.5 text-[11px] uppercase tracking-[0.16em] text-ink-faint">
            <Show when={q.data} fallback={<>taking stock <Spinner /></>}>
              {previews().length} serving
              <Show when={sub()}>{(s) => <> · substrate {s().up}/{s().total} up</>}</Show>
            </Show>
          </span>
        </div>
      </header>

      <section class="machine-bus flex flex-col gap-3 pb-6">
        {/* every server is a tap on the bus — branch identity first, the left stripe carries health */}
        <Show
          when={previews().length > 0}
          fallback={
            <Show when={q.data}>
              <div class="flex">
                <div class="machine-tap tap-off" />
                <div class="min-w-0 flex-1 rounded-[10px] border border-dashed border-rule px-[16px] py-[16px]">
                  <p class="m-0 text-[13.5px] text-ink-dim">Nothing serving.</p>
                  <p class="mt-1.5 mb-0 text-[12px] leading-[1.6] text-ink-faint">
                    Run main below, or open any branch's node and press ▷ preview — its server lands here, tapped into the same substrate.
                  </p>
                </div>
              </div>
            </Show>
          }
        >
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
                <div class="flex">
                  <div class="machine-tap" classList={{ "tap-off": p().health === "dead" || p().health === "orphaned" }} />
                  <div class={`card min-w-0 flex-1 rounded-[10px] border border-rule border-l-[3px] bg-vellum-raise px-[15px] py-[12px] transition-[border-color] duration-[250ms] ${h().stripe} ${h().card ?? ""}`}>
                    <div class="flex items-baseline gap-2.5">
                      <span class="truncate text-[14.5px] font-semibold text-ink" title={p().dir}>{p().branch || p().name}</span>
                      <Show when={p().managed === false}>
                        <span class="flex-none rounded border border-ember px-1.5 py-px text-[9px] uppercase tracking-[0.08em] text-ember" title="a next-dev listener no preview session owns — started outside the viewer (task dev, leftover headless server)">unmanaged</span>
                      </Show>
                      <span class="ml-auto flex-none text-[11px] text-ink-faint">{p().age}</span>
                    </div>
                    <div class="mt-[6px] flex flex-wrap items-baseline gap-x-3 gap-y-1">
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
                    <div class="mt-2 flex flex-wrap items-center gap-[5px] text-[10px] text-ink-faint" title="each preview runs its own worktree but borrows main's node_modules + .env, and shares the one substrate below">
                      <span class={CONN_NODE}>⌂ {shortDir(p().dir)}</span>
                      <Show when={p().managed === false}><span class={CONN_NODE}>pid {p().pid}</span></Show>
                    </div>
                    <div class="mt-2.5 flex items-center gap-[7px]">
                      {/* restart/log only make sense for servers the viewer owns — an unmanaged
                          stray has no session to respawn and no log file to tail */}
                      <Show when={p().managed !== false}>
                        <button class={BTN} disabled={busy() === p().dir + p().port} onClick={() => act(p(), "/preview-restart")}>
                          {busy() === p().dir + p().port ? "…" : "restart"}
                        </button>
                        <button class={BTN} onClick={() => showLog(p().dir)}>{logFor() === p().dir ? "hide log" : "log"}</button>
                        {/* before/after: flip this SAME port to another branch's build — the stamp proves each flip */}
                        <Show
                          when={swapPrev()[p().port]}
                          fallback={
                            <Show when={p().swapTo}>
                              <button class={BTN} disabled={busy() === p().dir + p().port} title={`kill + relaunch :${p().port} serving ${p().swapTo} — same tab, other build`} onClick={() => doSwap(p(), { branch: p().swapTo }, true)}>
                                {busy() === p().dir + p().port ? "…" : `⇄ ${p().swapTo}`}
                              </button>
                            </Show>
                          }
                        >
                          {(prev) => (
                            <button class={BTN} disabled={busy() === p().dir + p().port} title={`swing :${p().port} back to ${prev().label}`} onClick={() => doSwap(p(), { dir: prev().dir }, false)}>
                              {busy() === p().dir + p().port ? "…" : `⇄ back to ${prev().label}`}
                            </button>
                          )}
                        </Show>
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
                        class="mt-[9px] h-[min(50vh,480px)] overflow-auto rounded-[7px] border border-rule bg-diff-bg px-3 py-2.5 text-[11.5px] leading-[1.6] whitespace-pre-wrap text-ink-dim"
                      >{logText()}</pre>
                    </Show>
                  </div>
                </div>
              );
            }}
          </Index>
        </Show>

        {/* the levers row — always present: this is the page's front door even at zero */}
        <div class="flex">
          <div class="machine-tap tap-off" />
          <div class="flex min-w-0 flex-1 flex-wrap items-center gap-x-2.5 gap-y-1.5 rounded-[10px] border border-rule px-[13px] py-[10px]">
            <Show when={q.data} fallback={<span class="inline-flex items-center gap-1.5 text-[11px] text-ink-faint">finding servers <Spinner /></span>}>
              <Show when={!mainSrv()} fallback={<span class="text-[10.5px] text-ink-faint">main is serving above</span>}>
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
              </Show>
              <Show when={previews().length > 0}>
                <span class="ml-auto inline-flex items-center gap-[7px]">
                  <button class={BTN} disabled={busy() === "__all__"} onClick={reap}>reap orphaned</button>
                  <button class={`${BTN_SHAPE} border-del text-del opacity-85 enabled:hover:bg-del-bg enabled:hover:opacity-100`} disabled={busy() === "__all__"} onClick={killAll}>kill all</button>
                </span>
              </Show>
            </Show>
          </div>
        </div>
      </section>

      {/* the terminus — the ONE substrate every tap above flows into; full width on purpose:
          everything on this page rests on it */}
      <section class="machine-terminus rounded-[10px] border border-rule bg-vellum-raise px-[17px] py-[14px]">
        <div class="flex flex-wrap items-center gap-2.5">
          <Show
            when={sub()}
            fallback={<>
              <span class="h-[8px] w-[8px] flex-none animate-breathe rounded-full bg-ink-faint motion-reduce:animate-none" />
              <span class="font-display text-[16px] italic text-ink">Shared substrate</span>
              <span class="text-[11px] text-ink-faint">taking stock…</span>
            </>}
          >
            {(s) => (<>
              <span
                class="h-[8px] w-[8px] flex-none rounded-full"
                classList={{
                  "bg-add shadow-[0_0_6px_rgba(143,174,122,0.5)]": s().total > 0 && s().up >= s().total,
                  "animate-breathe bg-ember motion-reduce:animate-none": stackStarting() && s().up < s().total,
                  "bg-del shadow-[0_0_6px_rgba(200,122,85,0.5)]": !stackStarting() && (s().total === 0 || s().up < s().total),
                }}
              />
              <span class="font-display text-[16px] italic text-ink">Shared substrate</span>
              <span class="text-[11px] text-ink-dim">{s().up}/{s().total} services up · booted from {shortDir(s().dir ?? s().project)}</span>
              <Show when={s().total === 0 || s().up < s().total}>
                <button class={`${BTN} ml-auto flex-none whitespace-nowrap`} disabled={stackStarting()} onClick={startStack}>
                  {stackStarting() ? <>starting… <Spinner /></> : "▷ start stack"}
                </button>
              </Show>
            </>)}
          </Show>
        </div>
        <p class="mt-2 mb-0 text-[11px] leading-[1.6] text-ink-dim">
          One stack for everything — every server above reads and writes the same data. Swaps and previews isolate code, never data.
        </p>
        {/* the live stack is whichever compose project holds the ports — often a worktree's, and
            compose scopes volumes per project, so that stack's data is not main's */}
        <Show when={sub()?.home === false && sub()?.dir}>
          <p class="mt-[7px] mb-0 text-[10.5px] leading-[1.5] text-ember opacity-85">
            running from {shortDir(sub()!.dir!)} — its own Postgres/ClickHouse volumes, not main's
          </p>
        </Show>
        {/* a preview probes HEALTHY against a database with no tables — say so before its first query does */}
        <Show when={sub()?.db === "empty"}>
          <p class="mt-[7px] mb-0 text-[11px] leading-[1.5] text-del">
            this Postgres has no app schema — every query will fail until <code class="text-ink-dim">task dev:migrate</code> runs
          </p>
        </Show>
        <Show when={sub()?.err}>
          {(e) => <p class="mt-[7px] mb-0 text-[11px] leading-[1.5] text-del">docker compose up: {e()}</p>}
        </Show>
        {/* the invisible hazard made visible: a branch migrated (or lagged) the shared DB */}
        <Show when={drift()}>
          {(sc) => (
            <p class="mt-[7px] mb-0 text-[11px] leading-[1.6] text-ember" title={`applied heads — pg: ${sc().pg?.head || "?"} · ch: ${sc().ch?.head || "?"}`}>
              schema drift vs main: {driftBits(sc())}
            </p>
          )}
        </Show>
        <Show when={inStep()}>
          <p class="mt-[7px] mb-0 text-[11px] leading-[1.5] text-ink-faint" title={`applied heads — pg: ${sub()?.schema?.pg?.head || "?"} · ch: ${sub()?.schema?.ch?.head || "?"}`}>
            schema in step with main
          </p>
        </Show>
        <div class="mt-2.5 flex flex-wrap gap-1">
          <Show when={sub()}>
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
    </div>
  );
}
