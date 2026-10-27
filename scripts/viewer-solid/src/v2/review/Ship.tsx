// Where the branch stands on its way to main, as one line under the title on every tab, offering
// only the next step: run the gates (and why — the red ones, with skip), wait for them, push (and
// the push as it happens), or open the PR — and nothing once there's nothing to do. Gates show only
// while something waits to be pushed: a word until they need you, the gate in flight while running,
// the red ones by name. Beside it, ⟲ sync when the branch needs one (dirt, drift, behind main, an
// unvoiced tail), and under it the sync's steps while one runs — each failing step with its reason
// in full, and the dirt decision inline.
import { createEffect, createResource, createSignal, For, onCleanup, onMount, Show } from "solid-js";
import { gateRows, type GateRow, type Progress } from "../gates";
import { model } from "../model";
import { keyOf } from "../registry";
import { bind, runOf } from "../runner";
import { pushRoute } from "../commands/branch";
import { inspecting, motionOf } from "../commands/sync";
import Key from "../Key";
import { PHASE_WORD, syncNeeds, type PrepRoute, type SyncFacts } from "../syncing";
import { view, world } from "../store";
import { getJSON } from "../sync";
import { armed, now } from "../ui";
import { atRepoPath, page as pg } from "./page";

const secs = (ms: number | null) => (ms == null ? "" : ms >= 60000 ? `${Math.floor(ms / 60000)}m ${Math.round((ms % 60000) / 1000)}s` : `${Math.round(ms / 1000)}s`);

export default function ShipLine() {
  const id = () => pg.id();
  const v = () => model.branchView(id());
  const b = () => v()?.b;
  const [progress, { refetch }] = createResource(
    () => (b() ? `${b()!.repo}|${b()!.name}|${b()!.tip}|${b()!.gates}` : null),
    () => getJSON<Progress>(atRepoPath(b()!.repo, `/gates-progress?branch=${encodeURIComponent(b()!.name)}`)).catch(() => null),
  );
  createEffect(() => {
    if (!progress()?.running) return;
    const t = window.setTimeout(() => void refetch(), 2000);
    onCleanup(() => clearTimeout(t));
  });
  const rows = () => (now(), gateRows(progress(), Date.now() / 1000));
  const running = () => rows().find((g) => g.state === "running");
  const red = () => rows().filter((g) => g.state === "red");
  const waived = () => rows().filter((g) => g.state === "waived");
  const skipped = () => waived().filter((g) => g.summary?.endsWith("skipped by you")).map((g) => g.name);
  const route = () => pushRoute(id());
  const warm = () => !!world.entities.warm[b()?.repo ?? ""]?.prs;

  const push = () => runOf("branch.push.confirm", id());
  /** a push in flight, or one that failed: the button carries it until the next step takes over */
  const live = () => {
    const st = push()?.state;
    return st === "sending" || st === "landing" || st === "failed" ? st : null;
  };
  const acts = () => route() === "branch.gates.run" || route() === "branch.push.arm" || route() === "branch.push.confirm";
  const label = () => {
    if (live() === "sending") return "pushing…";
    if (live() === "landing") return "✓ pushed";
    if (live() === "failed") return "retry the push";
    if (route() === "branch.gates.run") return b()!.gates === "red" ? "re-run the gates" : "run the gates";
    if (armed() === id()) return `${keyOf("review.push")} again to push`;
    return `push ${b()!.pushed === "local" ? b()!.commits : b()!.ahead}`;
  };

  // dirt and the prep route are read per branch (GET /sync, /prep-route — memoised on the server):
  // /state can't carry them cheaply. Re-read when the branch moves, a sync ends, or the tab comes back.
  const [back, setBack] = createSignal(0);
  onMount(() => {
    const on = () => setBack((n) => n + 1);
    window.addEventListener("focus", on);
    onCleanup(() => window.removeEventListener("focus", on));
  });
  const motion = () => motionOf(id());
  const readKey = () => {
    const x = b();
    return x && x.tip ? `${x.repo}|${x.name}|${x.tip}|${x.pushed}|${x.ahead}|${x.behind}|${x.drifted}|${motion()?.phase ?? ""}|${back()}` : null;
  };
  const q = (path: string) => `${path}?branch=${encodeURIComponent(b()!.name)}`;
  const [facts] = createResource(readKey, () => getJSON<SyncFacts>(atRepoPath(b()!.repo, q("/sync"))).catch(() => null));
  const [prep] = createResource(readKey, () => getJSON<PrepRoute>(atRepoPath(b()!.repo, q("/prep-route"))).catch(() => null));
  const needs = () => (b() ? syncNeeds(b()!, facts.latest, prep.latest) : []);
  /** what the last sync left to say: a hand-off to Claude only until the tip moves */
  const said = () => {
    const m = motion();
    if (!m || m.phase === "running" || m.phase === "done") return "";
    if ((m.phase === "conflict" || m.phase === "claude") && b()?.tip !== m.tip) return "";
    return PHASE_WORD[m.phase];
  };
  const doing = () => {
    const m = motion();
    const s = m?.phase === "running" ? m.steps.find((x) => x.state === "run") : undefined;
    return s ? `⟲ ${s.label}…` : "";
  };

  return (
    <Show when={b()}>
      <span class="rv-ship">
        <Show when={doing()} fallback={
          <Show when={said()} fallback={
            <Show when={needs().length}>
              <button class="rv-btn" onClick={bind("review.sync", id())} title={`sync — ${needs().join(" · ")}`}>
                ⟲ sync <Key id="review.sync" />
              </button>
            </Show>
          }>
            <span class={motion()?.phase === "restacking" ? "text-gold-leaf" : "text-ember"}>{said()}</span>
          </Show>
        }>
          <span class="text-gold-leaf animate-breathe">{doing()}</span>
        </Show>
        <Show when={acts() && !live()}>
          <Show when={running()} fallback={<Gates red={red()} waived={waived()} gates={b()!.gates} skipped={skipped()} />}>
            <span class="text-gold-leaf">◌ {running()!.name} {secs(running()!.ms)}</span>
          </Show>
        </Show>
        <Show when={acts() || live()}>
          <button
            class="rv-btn rv-btn-gold"
            classList={{ "animate-breathe": live() === "sending", "text-ember": live() === "failed" }}
            disabled={live() === "sending" || live() === "landing"}
            title={live() === "failed" ? push()!.err : undefined}
            onClick={bind("review.push", id())}
          >
            {label()} <Show when={!live() || live() === "failed"}><kbd>{keyOf("review.push")}</kbd></Show>
          </button>
        </Show>
        <Show when={!acts() && !live() && !v()?.pr && v()?.st.action === "pr" && warm()}>
          <button class="rv-btn rv-btn-gold" onClick={bind("review.finish", id())}>
            open the PR ↗ <kbd>{keyOf("review.finish")}</kbd>
          </button>
        </Show>
      </span>
      <Show when={motion()}>
        <Strip id={id()} files={motion()!.dirt?.files ?? []} />
      </Show>
      <Show when={inspecting() === id()}>
        <Divergence repo={b()!.repo} name={b()!.name} />
      </Show>
    </Show>
  );
}

const ICON = { ok: "✓", fail: "✗", run: "⟳", skip: "↷", idle: "·" } as const;

/** The sync's steps: every one visible, a failing step's reason in full, the dirt decision inline. */
function Strip(props: { id: string; files: string[] }) {
  const m = () => motionOf(props.id);
  return (
    <div class="rv-strip">
      <div class="rv-strip-row">
        <For each={m()?.steps ?? []}>
          {(s) => (
            <span class="rv-step" data-state={s.state}>
              <i>{ICON[s.state]}</i>
              {s.label}
            </span>
          )}
        </For>
        <span class="flex-1" />
        <Show when={m()?.phase !== "running" && m()?.phase !== "dirt"}>
          <button class="rv-quietbtn" title="put the steps away" onClick={bind("review.sync.dismiss", props.id)}>
            ×
          </button>
        </Show>
      </div>
      <For each={(m()?.steps ?? []).filter((s) => s.note)}>
        {(s) => (
          <div class="rv-step-note" data-state={s.state}>
            <b>{s.label}</b> {s.note}
          </div>
        )}
      </For>
      <Show when={m()?.phase === "dirt"}>
        <div class="rv-dirt">
          <For each={props.files}>{(f) => <code>{f}</code>}</For>
          <div class="rv-dirt-acts">
            <button class="rv-btn rv-btn-gold" onClick={bind("review.sync.fold", props.id)} title="stage and commit everything in the holding worktree; the commit-shape step folds it into the outgoing commit">
              fold into the commit
            </button>
            <button class="rv-btn" onClick={bind("review.sync.stash", props.id)} title="stash (untracked too), run the sync, pop the stash after">
              stash &amp; continue
            </button>
            <button class="rv-btn" onClick={bind("review.sync.stop", props.id)} title="stop — the working tree stays exactly as it is">
              stop
            </button>
          </div>
        </div>
      </Show>
    </div>
  );
}

interface Detail {
  upstream: string;
  ahead: { sha: string; subject: string; matched: boolean; fromMain: boolean }[];
  behind: { sha: string; subject: string; matched: boolean }[];
  containment: string;
  overlap: string[];
  prNow: string;
  prAfter: string;
}

const CONTAINMENT: Record<string, string> = {
  rebase: "a rebase — origin's commits are all here, rewritten",
  contained: "origin's content is already here",
  "clean-extra": "origin has changes local lacks — they merge cleanly",
  overlap: "both sides changed the same places",
};

/** What a divergence is: each side's commits (twins marked), whether local contains origin, the PR before and after a push. */
function Divergence(props: { repo: string; name: string }) {
  const [d] = createResource(
    () => `${props.repo}|${props.name}`,
    () => getJSON<Detail>(atRepoPath(props.repo, `/diverged-detail?branch=${encodeURIComponent(props.name)}`)).catch(() => null),
  );
  return (
    <div class="rv-strip">
      <Show when={d()} fallback={<span>{d.loading ? "…" : "couldn't read the divergence"}</span>}>
        <div class="rv-step-note">
          <b>vs {d()!.upstream}</b> {CONTAINMENT[d()!.containment] ?? d()!.containment}
          {d()!.overlap.length ? ` — ${d()!.overlap.join(", ")}` : ""}
        </div>
        <div class="rv-step-note">
          <b>only here</b>
          <For each={d()!.ahead}>{(c) => <div class={c.matched || c.fromMain ? "text-ink-faint" : ""}>{c.sha} {c.subject}{c.matched ? " · twin on origin" : c.fromMain ? " · main's" : ""}</div>}</For>
        </div>
        <div class="rv-step-note">
          <b>only on origin</b>
          <For each={d()!.behind}>{(c) => <div class={c.matched ? "text-ink-faint" : ""}>{c.sha} {c.subject}{c.matched ? " · twin here" : ""}</div>}</For>
        </div>
        <div class="rv-step-note">
          <b>the PR</b> now {d()!.prNow || "empty"} · after a push {d()!.prAfter || "empty"}
        </div>
      </Show>
    </div>
  );
}

/** The gates as a word: ✓, stale, not run — or the red ones by name, each with skip. */
function Gates(props: { red: GateRow[]; waived: GateRow[]; gates: string; skipped: string[] }) {
  return (
    <Show
      when={props.red.length}
      fallback={
        <span class={props.gates === "green" ? "text-patina" : "text-ink-faint"} title={props.waived.map((g) => g.summary).join("\n") || undefined}>
          {props.gates === "green" ? `gates ✓${props.waived.length ? ` (${props.waived.length} skipped)` : ""}` : props.gates === "stale" ? "gates stale" : props.gates === "running" ? "gates queued" : "gates not run"}
        </span>
      }
    >
      <span class="text-ember">gates ✗</span>
      <For each={props.red}>
        {(g) => (
          <span class="ml-2" title={g.summary}>
            <span class="text-ember">{g.name}</span>{" "}
            <button class="rv-quietbtn" onClick={bind("branch.gates.skip", `${pg.id()} ${[...props.skipped, g.name].join(",")}`)}>
              skip
            </button>
          </span>
        )}
      </For>
    </Show>
  );
}

/** The commits list's first row: the commit that lands on main — the PR's title, once squashed. */
export function landingTitle(): string {
  const c = pg.conv();
  if (c) return c.title;
  return view("branch", pg.id())?.description ?? "";
}
