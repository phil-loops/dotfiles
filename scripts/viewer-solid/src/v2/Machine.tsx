// The machine: every dev server this workstation runs, the one shared stack they all read and
// write, and what the tooling costs the box. A server row says where it stands in a dot and a
// word and opens on ↵; its levers show on the selected row; every kill takes a second press.
import { createEffect, For, Index, onCleanup, onMount, Show } from "solid-js";
import Key from "./Key";
import { drift, machine, mkey, sid, type Server } from "./workstation";
import { model } from "./model";
import { keyOf } from "./registry";
import { bind, dispatch, runOf } from "./runner";
import { armed } from "./ui";

const HEALTH: Record<string, { word: string; dot: string; text: string; breathe?: boolean; faded?: boolean }> = {
  healthy: { word: "healthy", dot: "bg-add", text: "text-ink-faint" },
  compiling: { word: "compiling", dot: "bg-ember", text: "text-ember", breathe: true },
  starting: { word: "starting", dot: "bg-ember", text: "text-ember", breathe: true },
  error: { word: "error", dot: "bg-del", text: "text-del" },
  wedged: { word: "not responding", dot: "bg-del", text: "text-del" },
  dead: { word: "dead", dot: "bg-ink-faint", text: "text-ink-faint", faded: true },
  orphaned: { word: "orphaned", dot: "bg-ink-faint", text: "text-ink-faint", faded: true },
};
const shortDir = (d: string) => d.split("/").filter(Boolean).pop() ?? d;
const gb = (mb: number) => (mb / 1024).toFixed(1);
const ago = (s: number) => (s < 3600 ? `${Math.floor(s / 60)}m` : `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`);
const busy = (id: string, target: string) => {
  const s = runOf(id, target)?.state;
  return s === "sending" || s === "landing";
};

/** A lever: the command's key and its word, dispatched by click like by key. */
function Lever(props: { id: string; target?: string; word: string; danger?: boolean }) {
  return (
    <button
      class="inline-flex items-baseline gap-1.5 rounded-[5px] border px-2 py-px text-[11px] transition-colors duration-150"
      classList={{ "border-del/70 text-del hover:bg-del-bg": !!props.danger, "border-rule text-ink-dim hover:border-ink-faint hover:text-ink": !props.danger }}
      onClick={bind(props.id, props.target)}
    >
      <Key id={props.id} />
      {props.word}
    </button>
  );
}

function Row(props: { s: Server }) {
  const id = () => sid(props.s);
  const on = () => model.selected() === mkey(id());
  const h = () => HEALTH[props.s.health] ?? { word: props.s.health, dot: "bg-ink-faint", text: "text-ink-dim" };
  const owned = () => props.s.managed !== false;
  const doing = () =>
    busy("machine.stop", id()) ? "killing…" : busy("machine.restart", id()) ? "restarting…" : busy("machine.swap", id()) ? "swapping…" : "";
  const back = () => machine.swapped()[props.s.port];
  const swapWord = () => (back() ? `⇄ back to ${back()!.label}` : props.s.swapTo ? `⇄ ${props.s.swapTo}` : "");
  return (
    <div data-row={mkey(id())}>
      <div
        class="flex min-h-[38px] cursor-default items-center gap-3 border-l-2 px-4 pl-[42px] transition-colors duration-150"
        classList={{
          "border-gold-leaf bg-gold-wash": on(),
          "border-transparent hover:bg-vellum-raise": !on(),
          "opacity-60": !!h().faded || !!doing(),
          "ring-1 ring-inset ring-del/60": armed() === `kill ${id()}`,
        }}
        onClick={bind("cursor.set", mkey(id()))}
        onDblClick={bind("machine.open", id())}
      >
        <span class="h-[7px] w-[7px] shrink-0 rounded-full" classList={{ [h().dot]: true, "animate-breathe": !!h().breathe || !!doing() }} />
        <span class="min-w-0 truncate font-display text-[17px]" classList={{ "text-gold-leaf": on(), "text-ink": !on() }} title={props.s.dir}>
          {props.s.branch || props.s.name}
        </span>
        <Show when={!owned()}>
          <span class="shrink-0 text-[11px] text-ember" title="a next-dev listener no preview session owns — task dev, or a leftover headless server">
            unmanaged
          </span>
        </Show>
        <span class="flex-1" />
        <span class="shrink-0 whitespace-nowrap text-right text-[11px]" classList={{ [h().text]: !doing(), "text-ink-dim": !!doing() }}>
          {doing() || `${h().word}${props.s.latency != null ? ` · ${props.s.latency}ms` : ""}`}
        </span>
        <span class="w-[52px] shrink-0 text-right font-mono text-[11px] text-ink-faint">:{props.s.port}</span>
        <span class="w-[52px] shrink-0 text-right text-[11px] text-ink-faint">{props.s.age}</span>
      </div>
      <Show when={props.s.error || props.s.servesMismatch}>
        <p class="m-0 truncate pl-[62px] pr-4 text-[12px] text-del" title={props.s.error || props.s.serves}>
          {props.s.servesMismatch ? `⚠ the port serves ${props.s.serves}` : props.s.error}
        </p>
      </Show>
      <Show when={on()}>
        <div class="flex flex-wrap items-center gap-x-3 gap-y-1.5 bg-gold-wash pb-2 pl-[62px] pr-4 text-[12px] text-ink-faint">
          <span title="its own worktree; main's node_modules and .env; the one stack below">⌂ {shortDir(props.s.dir)}</span>
          <Show when={!owned() && props.s.pid}>
            <span>pid {props.s.pid}</span>
          </Show>
          <Show when={props.s.behind && props.s.behind !== "0"}>
            <span class="text-ember" title="the checkout it serves trails origin/main — healthy means answering, not fresh">{props.s.behind} behind main</span>
          </Show>
          <Show when={props.s.serves && !props.s.servesMismatch}>
            <span title={props.s.serves}>✓ {props.s.serves!.split(" ")[0]}</span>
          </Show>
          <span class="flex-1" />
          <Show when={props.s.url}>
            <Lever id="machine.open" target={id()} word="open" />
          </Show>
          <Show when={owned()}>
            <Lever id={machine.logFor() === id() ? "machine.log.close" : "machine.log"} target={id()} word="log" />
            <Lever id="machine.restart" target={id()} word="restart" />
            <Show when={swapWord()}>
              <Lever id="machine.swap" target={id()} word={swapWord()} />
            </Show>
          </Show>
          <Lever id="machine.kill" target={id()} word={armed() === `kill ${id()}` ? `again kills it · ${keyOf("overlay.close")}` : "kill"} danger />
        </div>
      </Show>
      <Show when={machine.logFor() === id()}>
        <Log s={props.s} />
      </Show>
    </div>
  );
}

/** The open log: follows new output while you're at the bottom; scrolling up holds it still. */
function Log(props: { s: Server }) {
  let pre: HTMLPreElement | undefined;
  let pinned = true;
  createEffect(() => {
    machine.log();
    if (pre && pinned) pre.scrollTop = pre.scrollHeight;
  });
  return (
    <div class="mb-3 ml-[62px] mr-4 mt-1">
      <Show when={props.s.jobs}>
        <div class="mb-1 flex items-baseline gap-3 text-[11px]">
          <For each={["web", "jobs"] as const}>
            {(src) => <span classList={{ "text-ink": machine.logSrc() === src, "text-ink-faint": machine.logSrc() !== src }}>{src === "jobs" ? "jobs worker" : "web"}</span>}
          </For>
          <Lever id="machine.log.jobs" target={sid(props.s)} word="switch" />
        </div>
      </Show>
      <pre
        ref={pre}
        onScroll={() => {
          if (pre) pinned = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 40;
        }}
        class="m-0 h-[min(50vh,480px)] overflow-auto border border-rule bg-diff-bg px-3 py-2 text-[11.5px] leading-[1.6] whitespace-pre-wrap text-ink-dim"
      >
        {machine.log() ?? "…"}
      </pre>
    </div>
  );
}

function Servers() {
  const n = () => machine.servers().length;
  return (
    <section class="mb-8">
      <div class="mb-1 flex items-baseline gap-3 px-4 pl-11">
        <h2 class="m-0 text-[11px] font-normal uppercase tracking-[0.14em] text-ink-faint">serving · {n()}</h2>
        <span class="flex-1" />
        <Show when={n() > 0}>
          <span class="flex gap-2">
            <Lever id="machine.reap" word={armed() === "reap" ? `again reaps · ${keyOf("overlay.close")}` : "reap orphaned"} danger={armed() === "reap"} />
            <Lever id="machine.killall" word={armed() === "kill all" ? `again kills ${n()} · ${keyOf("overlay.close")}` : "kill all"} danger />
          </span>
        </Show>
      </div>
      <Index each={machine.servers()} fallback={<p class="m-0 px-4 pl-11 text-ink-faint">nothing serving</p>}>
        {(s) => <Row s={s()} />}
      </Index>
      <div class="mt-2 flex items-baseline gap-2 px-4 pl-11 text-[12px] text-ink-faint">
        <Show
          when={!machine.main()}
          fallback={<span>main serves on :{machine.main()!.port}</span>}
        >
          <Show when={!busy("machine.main", "machine")} fallback={<span class="animate-breathe text-ink-dim">starting main…</span>}>
            <Lever id="machine.main" word="run main" />
            <label class="flex items-center gap-1">
              port
              <input
                class="w-[46px] border border-rule bg-vellum-night px-1 text-center text-[11px] text-ink-dim focus:border-ink-faint focus:text-ink focus:outline-none"
                value={machine.mainPort()}
                onInput={(e) => machine.setMainPort(e.currentTarget.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") dispatch("machine.main", "key", { event: e });
                }}
              />
            </label>
          </Show>
        </Show>
      </div>
    </section>
  );
}

function Stack() {
  const s = () => machine.substrate();
  const starting = () => !!s()?.starting || busy("machine.stack", "machine");
  const down = () => !!s() && (s()!.total === 0 || s()!.up < s()!.total);
  const project = () => s()?.project ?? "";
  const svc = (n: string) => (project() && n.startsWith(project() + "-") ? n.slice(project().length + 1) : n.replace(/^loops-/, "")).replace(/-1$/, "");
  const heads = () => `applied heads — pg: ${s()?.schema?.pg?.head || "?"} · ch: ${s()?.schema?.ch?.head || "?"}`;
  return (
    <section class="mb-8 px-4 pl-11">
      <div class="mb-1 flex items-baseline gap-3">
        <h2 class="m-0 text-[11px] font-normal uppercase tracking-[0.14em] text-ink-faint">stack</h2>
        <Show when={s()} fallback={<span class="text-[12px] text-ink-faint">…</span>}>
          <span
            class="h-[7px] w-[7px] self-center rounded-full"
            classList={{ "bg-add": !down(), "animate-breathe bg-ember": down() && starting(), "bg-del": down() && !starting() }}
          />
          <span class="text-[12px] text-ink-dim">
            {s()!.up}/{s()!.total} up · from {shortDir(s()!.dir ?? s()!.project)}
          </span>
          <span class="flex-1" />
          <Show when={down()}>
            <Show when={!starting()} fallback={<span class="animate-breathe text-[12px] text-ember">starting…</span>}>
              <Lever id="machine.stack" word="start" />
            </Show>
          </Show>
        </Show>
      </div>
      <Show when={s()}>
        <div class="text-[12px] leading-[1.6]">
          <p class="m-0 text-ink-faint">every server above reads and writes this one stack — swaps isolate code, never data</p>
          <Show when={s()!.home === false && s()!.dir}>
            <p class="m-0 text-ember">from {shortDir(s()!.dir!)} — its own Postgres and ClickHouse, not main's</p>
          </Show>
          <Show when={s()!.doctor?.broken?.length}>
            <p class="m-0 text-del">{s()!.doctor!.broken.map((c) => `${c.name} — ${c.detail}`).join(" · ")}</p>
          </Show>
          <Show when={s()!.db === "empty"}>
            <p class="m-0 text-del">
              no app schema — every query fails until <code class="text-ink-dim">task dev:migrate</code>
            </p>
          </Show>
          <Show when={s()!.err}>
            <p class="m-0 text-del">compose up: {s()!.err}</p>
          </Show>
          <Show when={s()!.schema?.pg}>
            <Show when={drift(s()!.schema)} fallback={<p class="m-0 text-ink-faint" title={heads()}>schema in step with main</p>}>
              <p class="m-0 text-ember" title={heads()}>
                schema vs main: {drift(s()!.schema)}
              </p>
            </Show>
          </Show>
          <div class="mt-2 flex flex-wrap gap-1">
            <For each={s()!.services}>
              {(x) => (
                <span
                  class="border px-1.5 text-[11px]"
                  classList={{
                    "border-rule text-ink-dim": x.up,
                    "border-rule text-ink-faint opacity-70": !x.up && x.state === "done",
                    "border-del/70 text-del": !x.up && x.state !== "done",
                  }}
                  title={x.status}
                >
                  {svc(x.name)}
                  {x.state === "done" ? " · done" : x.state === "failed" ? " · exited" : ""}
                </span>
              )}
            </For>
          </div>
        </div>
      </Show>
    </section>
  );
}

function Footprint() {
  return (
    <section class="mb-8 px-4 pl-11">
      <Show when={machine.footprint()} fallback={<h2 class="m-0 text-[11px] font-normal uppercase tracking-[0.14em] text-ink-faint">footprint · …</h2>}>
        {(f) => {
          const m = () => f().machine;
          const used = () => m().activeMb + m().wiredMb + m().compressedMb;
          const pct = (mb: number) => `${Math.max(0, Math.min(100, (mb / Math.max(1, m().totalMb)) * 100))}%`;
          const caches = () => Object.values(f().server.caches).reduce((a, b) => a + b, 0);
          return (
            <>
              <div class="mb-1 flex flex-wrap items-baseline gap-3">
                <h2 class="m-0 text-[11px] font-normal uppercase tracking-[0.14em] text-ink-faint">footprint</h2>
                <span
                  class="h-[7px] w-[7px] self-center rounded-full"
                  classList={{ "bg-add": m().pressure === "ok", "animate-breathe bg-ember": m().pressure === "high", "bg-del": m().pressure === "critical" }}
                />
                <span class="text-[12px] text-ink-dim">
                  {gb(used())}/{gb(m().totalMb)} GB · {m().levelPct >= 0 ? `${m().levelPct}% headroom` : `${m().freeMb} MB free`} · swap {gb(m().swap.usedMb)}/{gb(m().swap.totalMb)} GB
                </span>
                <span class="flex-1" />
                <Show when={m().pressure !== "ok"}>
                  <span class="text-[12px]" classList={{ "text-ember": m().pressure === "high", "text-del": m().pressure === "critical" }}>
                    {m().pressure === "high" ? "pressure — dev may slow" : "critical — next dev dies here"}
                  </span>
                </Show>
              </div>
              <div class="mb-3 flex h-[5px] w-full overflow-hidden bg-vellum-edge" title="wired · active · compressed · inactive (reclaimable) · free">
                <div class="bg-ink-dim" style={{ width: pct(m().wiredMb) }} />
                <div class="bg-gold-leaf" style={{ width: pct(m().activeMb) }} />
                <div class="bg-ember" style={{ width: pct(m().compressedMb) }} />
                <div class="bg-rule" style={{ width: pct(m().inactiveMb) }} />
              </div>
              <div class="grid grid-cols-3 gap-x-8 gap-y-3 text-[12px] tabular-nums max-[720px]:grid-cols-1">
                <ol class="m-0 flex list-none flex-col p-0">
                  <For each={m().top.slice(0, 6)}>
                    {(p) => (
                      <li class="flex items-baseline gap-2">
                        <span class="w-[58px] shrink-0 text-right text-ink">{p.rssMb >= 1024 ? `${gb(p.rssMb)} GB` : `${p.rssMb} MB`}</span>
                        <span class="min-w-0 flex-1 truncate text-ink-dim">{p.name}</span>
                        <span class="shrink-0 text-ink-faint">{p.cpu.toFixed(0)}%</span>
                      </li>
                    )}
                  </For>
                </ol>
                <dl class="m-0 grid grid-cols-[auto_1fr] content-start gap-x-3">
                  <dt class="text-right text-ink">{f().repo.worktrees}</dt>
                  <dd class="m-0 text-ink-dim">worktrees</dd>
                  <dt class="text-right text-ink">{f().repo.scratch}</dt>
                  <dd class="m-0 text-ink-dim">review scratch</dd>
                  <dt class="text-right text-ink">{f().repo.nodeModulesClones}</dt>
                  <dd class="m-0 text-ink-dim">node_modules clones</dd>
                  <Show when={f().repo.disk.totalGb}>
                    <dt class="text-right text-ink">{f().repo.disk.pct}%</dt>
                    <dd class="m-0 text-ink-dim">
                      disk · {f().repo.disk.usedGb}/{f().repo.disk.totalGb} GB
                    </dd>
                  </Show>
                  <dt />
                  <dd class="m-0 text-ink-faint">
                    <Show when={f().repo.hygiene} fallback="hygiene not run yet">
                      {(hy) => `hygiene ${ago(Math.max(60, Math.floor(Date.now() / 1000 - hy().at)))} ago · relinked ${hy().stripped}`}
                    </Show>
                  </dd>
                </dl>
                <dl class="m-0 grid grid-cols-[auto_1fr] content-start gap-x-3">
                  <dt class="text-right text-ink">{f().server.rssMb} MB</dt>
                  <dd class="m-0 text-ink-dim">viewer · up {ago(f().server.uptimeS)}</dd>
                  <dt class="text-right text-ink">{f().server.threads}</dt>
                  <dd class="m-0 text-ink-dim">
                    threads · {f().server.children} child{f().server.children === 1 ? "" : "ren"}
                  </dd>
                  <dt class="text-right text-ink">{caches()}</dt>
                  <dd class="m-0 text-ink-dim" title={Object.entries(f().server.caches).map(([k, v]) => `${k}: ${v}`).join("\n")}>
                    cached answers
                  </dd>
                </dl>
              </div>
            </>
          );
        }}
      </Show>
    </section>
  );
}

export default function Machine() {
  onMount(() => onCleanup(machine.watch()));
  return (
    <Show when={machine.substrate()} fallback={<p class="px-4 pl-11 text-ink-faint">taking stock…</p>}>
      <div data-paint="machine" class="relative mx-auto max-w-[1080px] pt-2">
        <Servers />
        <Stack />
        <Footprint />
      </div>
    </Show>
  );
}
