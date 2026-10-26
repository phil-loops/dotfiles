// Forests, the home: focus (hand-ordered), the workbench, and a quiet archive count. Each forest is
// one calm row that opens inline into its branch spine, in merge order; each branch says where it
// stands in one glyph and word and does one thing on ↵. `r` narrows it all to what's ready for you.
import { createEffect, createMemo, createSignal, For, Show } from "solid-js";
import { shiftFor } from "./drag";
import { bkey, model, pkey, type BranchView, type ForestView } from "./model";
import { boot, catchIt, flip, settle } from "./motion";
import { keyOf } from "./registry";
import { bind } from "./runner";
import { fmtMorning, leaf, phaseAt, SHIP, windowLine } from "./ship";
import { view, world } from "./store";
import { page } from "./review/page";
import type { Project } from "./types";
import { armed, drag, expanded, launching, now, opened, readyOnly, setExpanded, setLaunching, showArchive, toggleIn } from "./ui";

/** Prefetch on intent: the cursor landing on a branch warms its review page's diff. */
function warmSelected(): void {
  createEffect(() => {
    const id = model.selectedBranch();
    const b = id ? view("branch", id) : undefined;
    if (b) page.warm(b.repo, b.name, b.tip);
  });
}

/** Forests whose last PR just landed, for the "canopy closed" moment before they fold away. */
const [closing, setClosing] = createSignal<ReadonlySet<string>>(new Set());

function watchClosings(): void {
  let was: Set<string> | null = null;
  createEffect(() => {
    if (!world.ready) return;
    const closed = new Set([...model.forests().values()].filter((f) => f.closed).map((f) => f.p.id));
    if (was) {
      for (const id of closed) {
        if (was.has(id)) continue;
        setClosing((s) => new Set(s).add(id));
        window.setTimeout(() => {
          setClosing((s) => new Set([...s].filter((x) => x !== id)));
          setExpanded((s) => toggleIn(s, id, false));
          setLaunching((l) => (l === id ? undefined : l));
        }, 2600);
      }
    }
    was = closed;
  });
}

function actionHint(v: BranchView): string {
  const go = keyOf("row.primary");
  if (armed() === v.b.id) return `${go} again sends it to origin · ${keyOf("overlay.close")}`;
  if (v.b.pending) return "";
  switch (v.st.action) {
    case "push":
      return `${go} push`;
    case "pr":
      return v.pr ? `${go} view #${v.pr.number}` : `${go} open PR`;
    default:
      return `${go} open`;
  }
}

function shipWord(v: BranchView): string {
  if (v.b.pending === "pushing") return "pushing…";
  if (v.st.ship === "pushed" && opened().has(v.b.id)) return "waiting for GitHub…";
  return SHIP[v.st.ship].word;
}

function BranchRow(props: { id: string; summary: string }) {
  const v = () => model.branchView(props.id)!;
  const key = () => bkey(v().b.id);
  const on = () => model.selected() === key();
  // gold means "you're acting here": the selected row and anything in flight. A row that is merely
  // ready reads brighter, not gold, so the ready filter doesn't turn the page gold.
  const live = () => !!v().b.pending || armed() === v().b.id;
  const meta = createMemo(() => {
    const b = v().b;
    const out: string[] = [];
    if (b.commits) out.push(`${b.commits} commit${b.commits === 1 ? "" : "s"}`);
    if (b.pushed === "ahead") out.push(`${b.ahead} ahead of origin`);
    if (!v().pr && b.gates !== "green" && b.commits) out.push(b.gates === "red" ? `red: ${b.redGates.join(", ") || "gates"}` : b.gates === "running" ? "gates running" : b.gates === "stale" ? "gates stale" : "not gated");
    if (b.holdUntil && !v().pr) out.push(`held for ${fmtMorning(Date.parse(b.holdUntil))}`);
    if (v().st.ship === "approved" && v().st.waiting[0]) out.push(`waiting on ${v().st.waiting[0].label}`);
    return out.join(" · ");
  });
  return (
    <li
      data-row={key()}
      data-ship={v().st.ship}
      class="flex h-[32px] cursor-default items-center gap-3 border-l-2 pl-10 pr-4 transition-colors duration-150"
      classList={{ "border-gold-leaf bg-gold-wash": on(), "border-transparent hover:bg-vellum-raise": !on(), "ring-1 ring-inset ring-gold-deep": armed() === v().b.id }}
      onClick={bind("cursor.set", key())}
    >
      <span class="w-4 text-right text-[11px] text-ink-faint">{v().b.order < 999 ? v().b.order : ""}</span>
      <span class="w-[172px] shrink-0 truncate" classList={{ "text-ink": !on(), "text-gold-leaf": on() }} title={v().b.name}>
        {leaf(v().b.name)}
      </span>
      <span class="min-w-0 flex-1 truncate text-ink-dim">{v().b.description === props.summary ? "" : v().b.description}</span>
      <Show when={`${v().st.ship}|${shipWord(v())}`} keyed>
        <span
          ref={settle}
          class="shrink-0 whitespace-nowrap text-right"
          classList={{ "text-gold-leaf": live(), "text-ink": !live() && v().st.ready, "text-ink-faint": !live() && !v().st.ready, "animate-breathe": !!v().b.pending || shipWord(v()).endsWith("…") }}
        >
          {SHIP[v().st.ship].glyph} {shipWord(v())}
        </span>
      </Show>
      <Show when={on() && meta()}>
        <span class="shrink-0 text-[11px]" classList={{ "text-del": v().b.gates === "red" && !v().pr, "text-ink-faint": v().b.gates !== "red" || !!v().pr }}>
          {meta()}
        </span>
      </Show>
      <Show when={on() && actionHint(v())}>
        <span class="shrink-0 text-gold-leaf">{actionHint(v())}</span>
      </Show>
    </li>
  );
}

function ForestRow(props: { f: ForestView; grip: boolean }) {
  const p = () => props.f.p;
  const key = () => pkey(p().id);
  const on = () => model.selected() === key();
  const isClosing = () => closing().has(p().id);
  const open = () => expanded().has(p().id) || readyOnly();
  const hint = () =>
    p().state === "archive" ? `${keyOf("row.primary")} restore` : props.f.closed ? `${keyOf("row.primary")} archive` : !props.f.branches.length ? "" : readyOnly() ? "" : `${keyOf("row.primary")} page`;
  const meta = () => {
    const f = props.f;
    if (p().state === "archive" || !f.branches.length) return "";
    const parts = [`${f.branches.length} branch${f.branches.length === 1 ? "" : "es"}`];
    if (f.ready.length) parts.push(`${f.ready.length} ready`);
    if (f.unopened.length > 1) parts.push(`${keyOf("forest.launch")} launch ${f.unopened.length}`);
    if (p().ticket) parts.push(p().ticket!);
    return parts.join(" · ");
  };
  return (
    <div
      data-row={key()}
      class="group flex h-[38px] cursor-default items-center gap-3 border-l-2 px-4 transition-colors duration-150"
      classList={{
        "border-gold-leaf bg-gold-wash": on(),
        "border-transparent hover:bg-vellum-raise": !on(),
        "v2-closing": isClosing(),
      }}
      onClick={bind("cursor.set", key())}
    >
      <span
        class="w-3 cursor-grab touch-none select-none text-ink-faint opacity-0 group-hover:opacity-100"
        classList={{ "opacity-100": on() && props.grip, invisible: !props.grip }}
        title="drag to reorder (C-k / C-j)"
        onPointerDown={bind("focus.drag", p().id)}
      >
        ⋮
      </span>
      <span
        class="w-[var(--fw)] shrink-0 truncate font-display text-[17px]"
        classList={{ "text-gold-leaf": on(), "text-ink": !on() && !props.f.closed, "text-ink-faint": !on() && props.f.closed }}
      >
        {p().name}
        <Show when={props.f.ready.length && !readyOnly()}>
          <span class="ml-1.5 align-middle text-[9px] text-gold-leaf" title={`${props.f.ready.length} ready for you`}>●</span>
        </Show>
      </span>
      <Show
        when={!isClosing() && !props.f.closed}
        fallback={<span class="flex-1 font-display italic text-gold-leaf/80" classList={{ "text-ink-faint": !isClosing() }}>✦ canopy closed</span>}
      >
        <span class="min-w-0 flex-1 truncate text-ink-dim">{p().summary}</span>
      </Show>
      <Show when={on() && meta()}>
        <span class="shrink-0 text-[11px] text-ink-faint">{meta()}</span>
      </Show>
      <Show when={on() && hint()}>
        <span class="shrink-0 text-gold-leaf">{hint()}</span>
      </Show>
    </div>
  );
}

function LaunchLine(props: { f: ForestView }) {
  const total = () => props.f.branches.filter((v) => v.st.ship !== "landed").length;
  const done = () => props.f.branches.filter((v) => v.st.ship !== "landed" && v.pr).length;
  return (
    <div class="ml-10 mr-4 flex items-center gap-3 py-1.5 text-[12px]">
      <span class="text-gold-leaf">launch</span>
      <span class="h-[3px] w-28 overflow-hidden rounded-full bg-vellum-edge">
        <span class="block h-full bg-gold-leaf transition-[width] duration-300" style={{ width: `${(100 * done()) / Math.max(1, total())}%` }} />
      </span>
      <Show when={done() < total()} fallback={<span class="font-display italic text-gold-leaf">✦ all on GitHub</span>}>
        <span class="text-ink-dim">
          {done()}/{total()} on GitHub
        </span>
      </Show>
    </div>
  );
}

function Block(props: { id: string; index: number }) {
  return <Show when={model.forests().get(props.id)}>{(f) => <BlockBody f={f()} index={props.index} />}</Show>;
}

function BlockBody(props: { f: ForestView; index: number }) {
  const focus = () => props.f.p.state === "focus";
  const dragging = () => drag()?.id === props.f.p.id;
  const branches = () => (readyOnly() ? props.f.ready : expanded().has(props.f.p.id) ? props.f.branches : []).map((v) => v.b.id);
  return (
    <div
      data-focus-block={focus() ? props.f.p.id : undefined}
      class="relative"
      classList={{ "z-10 bg-vellum-raise shadow-2xl": dragging(), "transition-transform duration-150": !!drag() && !dragging() }}
      style={{ transform: focus() && drag() ? `translateY(${shiftFor(props.index, props.f.p.id)}px)` : undefined }}
    >
      <ForestRow f={props.f} grip={focus()} />
      <Show when={launching() === props.f.p.id}>
        <LaunchLine f={props.f} />
      </Show>
      <Show when={branches().length}>
        <ul class="m-0 list-none p-0 pb-1">
          <For each={branches()}>{(id) => <Show when={model.branchView(id)}><BranchRow id={id} summary={props.f.p.summary} /></Show>}</For>
        </ul>
      </Show>
    </div>
  );
}

function Section(props: { title: string; rows: Project[]; empty: string }) {
  const views = () =>
    props.rows.filter((p) => {
      const f = model.forests().get(p.id);
      return !!f && (!readyOnly() || f.ready.length > 0);
    }).map((p) => p.id);
  return (
    <Show when={!readyOnly() || views().length}>
      <section class="mb-7">
        <h2 class="m-0 mb-1 px-4 pl-11 text-[11px] font-normal uppercase tracking-[0.14em] text-ink-faint">{props.title}</h2>
        <For each={views()} fallback={<p class="m-0 px-4 py-2 pl-11 text-ink-faint">{props.empty}</p>}>
          {(id, i) => <Block id={id} index={i()} />}
        </For>
      </section>
    </Show>
  );
}

function WindowLine() {
  const due = () =>
    [...model.forests().values()].flatMap((f) => f.branches).filter((v) => v.b.holdUntil && !v.pr && Date.parse(v.b.holdUntil) <= now()).length;
  const text = () => windowLine(now());
  const late = () => ["late", "weekend"].includes(phaseAt(now()).phase);
  return (
    <Show when={text() || due()}>
      <p data-window={phaseAt(now()).phase} class="m-0 mb-6 px-4 pl-11 font-display text-[15px] italic" classList={{ "text-ember": late(), "text-gold-leaf": !late() }}>
        {text()}
        <Show when={due()}>
          <span class="text-gold-leaf">
            {text() ? " · " : ""}☀ {due()} held overnight {due() === 1 ? "is" : "are"} due
          </span>
        </Show>
      </p>
    </Show>
  );
}

export default function Forests() {
  let root: HTMLDivElement | undefined;
  const p = () => model.projects();
  // the name column is as wide as the longest name shown (to a cap), so names don't cut while descriptions have room
  const nameWidth = () => Math.min(26, Math.max(14, ...[...p().focus, ...p().workbench, ...(showArchive() ? p().archive : [])].map((x) => x.name.length + 2)));
  const readyCount = () => [...model.forests().values()].filter((f) => f.p.state !== "archive").reduce((n, f) => n + f.ready.length, 0);
  flip(() => root, () => model.rows());
  watchClosings();
  warmSelected();
  boot();
  return (
    <Show when={world.ready} fallback={<p class="px-4 pl-11 text-ink-faint">reading the forests…</p>}>
      <div ref={root} data-paint="forests" class="relative mx-auto max-w-[980px]" style={{ "--fw": `${nameWidth()}ch` }}>
        <WindowLine />
        <Show when={readyOnly()}>
          <p class="m-0 mb-5 px-4 pl-11 text-ink-dim">
            <span class="text-gold-leaf">ready</span> · {readyCount() || "nothing"} ·{" "}
            <button class="text-ink-faint hover:text-ink-dim" onClick={bind("ready.toggle")}>show all</button>
          </p>
        </Show>
        <Section title="Focus" rows={p().focus} empty="empty" />
        <Section title="Workbench" rows={p().workbench} empty="empty" />
        <Show when={!readyOnly()}>
          <Show
            when={showArchive()}
            fallback={
              <Show when={p().archive.length} keyed>
                {(n) => (
                  <button ref={catchIt} class="ml-11 px-0 text-ink-faint hover:text-ink-dim" onClick={bind("archive.toggle")}>
                    archive · {n}
                  </button>
                )}
              </Show>
            }
          >
            <Section title="Archive" rows={p().archive} empty="empty" />
          </Show>
        </Show>
      </div>
    </Show>
  );
}
