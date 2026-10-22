// Where to focus next: every command and surface against its budget, most used and never used,
// refusals, the weekly trend, and v1 beside v2 — all from GET /telemetry/summary (daily rollups).
import { createResource, For, Show, type JSX } from "solid-js";
import { bind } from "./runner";
import { getJSON } from "./sync";
import { dashDays } from "./ui";

interface Stats {
  n: number;
  p50: number | null;
  p95: number | null;
}
interface Cmd {
  app: string;
  id: string;
  budget: string;
  budgetMs: { feedbackMs: number; settledMs: number | null };
  n: number;
  via: Record<string, number>;
  refusedRate: number;
  failedRate: number;
  topErr: string | null;
  feedback: Stats;
  settled: Stats;
  over: number | null;
  score: number;
}
interface Surf {
  app: string;
  id: string;
  n: number;
  paint: Stats;
  over: number | null;
}
interface Pair {
  kind: "cmd" | "nav";
  id: string;
  v1ids: string[];
  v2: (Cmd & Surf) | null;
  v1: ((Cmd & Surf) | { n: number; ids: string[] }) | null;
}
interface Summary {
  days: number;
  paintMs: number;
  commands: Cmd[];
  surfaces: Surf[];
  mostUsed: { app: string; id: string; n: number }[];
  neverUsed: string[];
  pairs: Pair[];
  weekly: { week: string; app: string; cmds: number; feedbackP95: number | null; settledP95: number | null; paintP95: number | null }[];
  pages: Record<string, { loads: number; longtasks: number; longtaskMsP95: number | null; clsP95: number | null }>;
  ms: number;
}

const ms = (v: number | null | undefined) => (v == null ? "—" : v >= 1000 ? `${(v / 1000).toFixed(1)}s` : `${Math.round(v)}ms`);
const pct = (v: number) => (v ? `${Math.round(v * 100)}%` : "—");

/** p95 against its budget: a bar to 2× budget, the budget tick at the middle, a word for status. */
function Meter(props: { value: number | null; budget: number | null | undefined }) {
  const ratio = () => (props.value != null && props.budget ? props.value / props.budget : null);
  return (
    <Show when={ratio() != null} fallback={<span class="text-ink-faint">—</span>}>
      <span class="inline-flex items-center gap-2" title={`p95 ${ms(props.value)} · budget ${ms(props.budget)}`}>
        <span class="relative inline-block h-[6px] w-[96px] bg-vellum-edge">
          <span
            class="absolute inset-y-0 left-0 rounded-r-[3px]"
            classList={{ "bg-ember": ratio()! > 1, "bg-patina": ratio()! <= 1 }}
            style={{ width: `${Math.min(100, (ratio()! / 2) * 100)}%` }}
          />
          <span class="absolute inset-y-[-2px] left-1/2 w-px bg-ink-faint" />
        </span>
        <span classList={{ "text-ember": ratio()! > 1, "text-ink-faint": ratio()! <= 1 }}>
          {ratio()! > 1 ? `✕ ${ratio()!.toFixed(1)}×` : "✓ in"}
        </span>
      </span>
    </Show>
  );
}

function Panel(props: { title: string; note?: string; children: JSX.Element }) {
  return (
    <section class="mb-10">
      <h2 class="m-0 font-display text-[19px] font-normal text-ink">{props.title}</h2>
      <Show when={props.note}>
        <p class="m-0 mb-3 text-ink-faint">{props.note}</p>
      </Show>
      <div class="overflow-x-auto">{props.children}</div>
    </section>
  );
}

const TH = "whitespace-nowrap py-1 pr-6 text-left font-normal text-[11px] uppercase tracking-[0.1em] text-ink-faint";
const TD = "whitespace-nowrap py-1 pr-6 align-baseline";

export default function Dashboard() {
  const [data] = createResource(dashDays, (d) => getJSON<Summary>(`/telemetry/summary?days=${d}`));
  return (
    <div class="max-w-[1100px] px-4">
      <div class="mb-6 flex items-baseline gap-4">
        <h1 class="m-0 font-display text-[26px] font-normal text-ink">Where to focus</h1>
        <button class="text-ink-faint hover:text-gold-leaf" onClick={bind("dashboard.range")}>
          last {dashDays()} days · t to change
        </button>
      </div>
      <Show when={data()} fallback={<p class="text-ink-faint">{data.error ? "couldn't read the telemetry" : "reading the telemetry…"}</p>}>
        {(s) => (
          <div data-paint="dashboard">
            <Panel title="Commands against their budgets" note="Worst first: how far p95 is over budget, weighted by use. Feedback is input → the frame that shows it; settled is input → the server's answer.">
              <table class="border-collapse">
                <thead>
                  <tr>
                    <th class={TH}>command</th><th class={TH}>app</th><th class={TH}>class</th><th class={TH}>runs</th>
                    <th class={TH}>feedback p50 / p95</th><th class={TH}>vs one frame</th><th class={TH}>settled p50 / p95</th><th class={TH}>vs budget</th>
                    <th class={TH}>refused</th><th class={TH}>failed</th>
                  </tr>
                </thead>
                <tbody>
                  <For each={s().commands.slice(0, 25)}>
                    {(c) => (
                      <tr>
                        <td class={`${TD} text-ink`}>{c.id}</td>
                        <td class={`${TD} text-ink-faint`}>{c.app}</td>
                        <td class={`${TD} text-ink-faint`}>{c.budget}</td>
                        <td class={TD}>{c.n}</td>
                        <td class={TD}>{ms(c.feedback.p50)} / {ms(c.feedback.p95)}</td>
                        <td class={TD}><Meter value={c.feedback.p95} budget={c.budgetMs.feedbackMs} /></td>
                        <td class={TD}>{c.settled.n ? `${ms(c.settled.p50)} / ${ms(c.settled.p95)}` : "—"}</td>
                        <td class={TD}><Meter value={c.settled.p95} budget={c.budgetMs.settledMs} /></td>
                        <td class={TD} title={c.topErr ?? ""}>{pct(c.refusedRate)}</td>
                        <td class={TD}>{pct(c.failedRate)}</td>
                      </tr>
                    )}
                  </For>
                </tbody>
              </table>
            </Panel>

            <Panel title="Surfaces: navigation to meaningful paint" note={`Budget ${ms(s().paintMs)}.`}>
              <table class="border-collapse">
                <thead>
                  <tr><th class={TH}>surface</th><th class={TH}>app</th><th class={TH}>visits</th><th class={TH}>paint p50 / p95</th><th class={TH}>vs budget</th></tr>
                </thead>
                <tbody>
                  <For each={s().surfaces}>
                    {(v) => (
                      <tr>
                        <td class={`${TD} text-ink`}>{v.id}</td>
                        <td class={`${TD} text-ink-faint`}>{v.app}</td>
                        <td class={TD}>{v.n}</td>
                        <td class={TD}>{ms(v.paint.p50)} / {ms(v.paint.p95)}</td>
                        <td class={TD}><Meter value={v.paint.p95} budget={s().paintMs} /></td>
                      </tr>
                    )}
                  </For>
                </tbody>
              </table>
            </Panel>

            <Panel title="v1 beside v2" note="Each v2 command or surface next to the v1 controls it replaces (declared in the registry).">
              <table class="border-collapse">
                <thead>
                  <tr><th class={TH}>what</th><th class={TH}>v1 as</th><th class={TH}>v1 runs</th><th class={TH}>v1 p95</th><th class={TH}>v2 runs</th><th class={TH}>v2 p95</th></tr>
                </thead>
                <tbody>
                  <For each={s().pairs}>
                    {(p) => {
                      const p95 = (x: Pair["v2"] | Pair["v1"]) =>
                        !x || !("id" in x) ? "—" : p.kind === "nav" ? ms(x.paint?.p95) : `${ms(x.feedback?.p95)} · ${ms(x.settled?.p95)}`;
                      return (
                        <tr>
                          <td class={`${TD} text-ink`}>{p.id}</td>
                          <td class={`${TD} text-ink-faint`}>{p.v1ids.join(", ")}</td>
                          <td class={TD}>{p.v1?.n ?? 0}</td>
                          <td class={TD}>{p95(p.v1)}</td>
                          <td class={TD}>{p.v2?.n ?? 0}</td>
                          <td class={TD}>{p95(p.v2)}</td>
                        </tr>
                      );
                    }}
                  </For>
                </tbody>
              </table>
              <p class="m-0 mt-1 text-ink-faint">commands read feedback · settled; surfaces read paint.</p>
            </Panel>

            <div class="grid gap-x-12 md:grid-cols-2">
              <Panel title="Most used">
                <For each={s().mostUsed} fallback={<p class="text-ink-faint">nothing yet</p>}>
                  {(c) => (
                    <div class="flex justify-between gap-6">
                      <span>{c.id} <span class="text-ink-faint">{c.app}</span></span>
                      <span>{c.n}</span>
                    </div>
                  )}
                </For>
              </Panel>
              <Panel title="Never used" note="Registered v2 commands with no run in this window — candidates to cut.">
                <For each={s().neverUsed} fallback={<p class="text-ink-faint">every command has been used</p>}>
                  {(id) => <div class="text-ink-dim">{id}</div>}
                </For>
              </Panel>
            </div>

            <Panel title="Weekly trend" note="p95s per week, so a regression shows up the week it lands.">
              <table class="border-collapse">
                <thead>
                  <tr><th class={TH}>week</th><th class={TH}>app</th><th class={TH}>runs</th><th class={TH}>feedback p95</th><th class={TH}>settled p95</th><th class={TH}>paint p95</th></tr>
                </thead>
                <tbody>
                  <For each={s().weekly}>
                    {(w) => (
                      <tr>
                        <td class={TD}>{w.week}</td><td class={`${TD} text-ink-faint`}>{w.app}</td><td class={TD}>{w.cmds}</td>
                        <td class={TD}>{ms(w.feedbackP95)}</td><td class={TD}>{ms(w.settledP95)}</td><td class={TD}>{ms(w.paintP95)}</td>
                      </tr>
                    )}
                  </For>
                </tbody>
              </table>
            </Panel>

            <Panel title="Page health" note="Per page load: long tasks (main thread blocked > 50 ms) and layout shift.">
              <For each={Object.entries(s().pages)}>
                {([app, p]) => (
                  <div>
                    {app}: {p.loads} loads · {p.longtasks} long tasks · long-task time p95 {ms(p.longtaskMsP95)} · layout shift p95 {p.clsP95 ?? "—"}
                  </div>
                )}
              </For>
            </Panel>
            <p class="text-ink-faint">summary computed in {ms(s().ms)}</p>
          </div>
        )}
      </Show>
    </div>
  );
}
