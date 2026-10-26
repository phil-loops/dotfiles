// Where the branch stands on its way to main, as one line under the title on every tab, offering
// only the next step: run the gates (and why — the red ones, with skip), wait for them, push (and
// the push as it happens), or open the PR — and nothing once there's nothing to do. Gates show only
// while something waits to be pushed: a word until they need you, the gate in flight while running,
// the red ones by name.
import { createEffect, createResource, createSignal, For, Match, onCleanup, Show, Switch } from "solid-js";
import { gateRows, type GateRow, type Progress } from "../gates";
import { model } from "../model";
import { keyOf } from "../registry";
import { bind, runOf } from "../runner";
import { pushRoute } from "../commands/branch";
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
  const [sent, setSent] = createSignal(0);
  createEffect(() => {
    if (push()?.state === "sending" && !sent()) setSent(b()?.ahead || 0);
  });
  const pushing = () => push() && push()!.state !== "done";

  return (
    <Show when={b()}>
      <span class="rv-ship">
        <Show
          when={!pushing()}
          fallback={
            <Switch>
              <Match when={push()!.state === "sending"}>
                <span class="text-gold-leaf animate-breathe">◌ pushing</span>
              </Match>
              <Match when={push()!.state === "landing"}>
                <span class="text-patina">✓ pushed</span>
              </Match>
              <Match when={push()!.state === "failed"}>
                <span class="text-ember">✗ {push()!.err}</span>{" "}
                <button class="rv-quietbtn" onClick={bind("review.push", id())}>
                  retry
                </button>
              </Match>
            </Switch>
          }
        >
          <Show when={route()}>
            <Show when={running()} fallback={<Gates red={red()} waived={waived()} gates={b()!.gates} skipped={skipped()} />}>
              <span class="text-gold-leaf">◌ {running()!.name} {secs(running()!.ms)}</span>
            </Show>
          </Show>
          <Show when={route() === "branch.gates.run" || route() === "branch.push.arm" || route() === "branch.push.confirm"}>
            <button class="rv-btn rv-btn-gold ml-2" onClick={bind("review.push", id())}>
              {route() === "branch.gates.run"
                ? b()!.gates === "red"
                  ? "re-run the gates"
                  : "run the gates"
                : armed() === id()
                  ? `${keyOf("review.push")} again to push`
                  : `push ${b()!.pushed === "local" ? b()!.commits : b()!.ahead}`}{" "}
              <kbd>{keyOf("review.push")}</kbd>
            </button>
          </Show>
          <Show when={!route() && !v()?.pr && v()?.st.action === "pr" && warm()}>
            <button class="rv-btn rv-btn-gold ml-2" onClick={bind("review.finish", id())}>
              open the PR ↗ <kbd>{keyOf("review.finish")}</kbd>
            </button>
          </Show>
          <Show when={sent() && push()?.state === "done"}>
            <span class="text-patina">✓ {sent()} on origin</span>
          </Show>
        </Show>
      </span>
    </Show>
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
