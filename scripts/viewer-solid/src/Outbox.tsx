// The outbox — the landing page, built around shipping. Four months of telemetry say the home page
// was a 3-second pass-through on the way to fix-the-words-then-push, and GitHub says the time goes
// before the push, in forests that drain one PR at a time. So home is now every unlanded branch,
// lane by lane, each row carrying the title that will land and the one action it's waiting for.
import { createEffect, createMemo, createSignal, For, Match, onCleanup, Show, Switch, type JSX } from "solid-js";
import { createQuery } from "@tanstack/solid-query";
import { useViewerLocation } from "./router";
import { canMutate } from "./provider";
import { fetchOutbox, useOutboxActions, type OutboxActions } from "./outboxActions";
import {
  LANES, laneItems, itemKey, summaryLabel,
  type Item, type Lane, type OutboxForest, type OutboxNode,
} from "./outboxModel";

const EYEBROW = "eyebrow text-[10px] font-medium tracking-[0.22em] uppercase text-ink-faint";
const ASK = "ml-2 font-display text-[14px] normal-case italic tracking-normal text-ink-dim";
const CHIP = "inline-flex flex-none items-center gap-[5px] rounded-[6px] border px-[7px] py-px font-mono text-[10.5px] leading-[1.6] whitespace-nowrap";
const BTN = "flex-none cursor-pointer rounded-[7px] border px-[11px] py-[3px] font-mono text-[11px] leading-[1.55] tracking-[0.02em] transition-[border-color,color,background] duration-[120ms] disabled:cursor-default disabled:opacity-45";
const BTN_GOLD = `${BTN} border-gold-deep text-gold-leaf hover:bg-gold-wash enabled:hover:border-gold-leaf`;
const BTN_QUIET = `${BTN} border-rule text-ink-dim hover:border-gold-deep hover:text-gold-leaf`;
const BTN_ARMED = `${BTN} border-gold-leaf bg-gold-leaf text-vellum-night`;

export function GatesChip(props: { n: OutboxNode }) {
  return (
    <Switch>
      <Match when={props.n.gates === "green"}>
        <span class={`${CHIP} border-[#3c4a30] text-add`} title="gates green for this exact tree">● green</span>
      </Match>
      <Match when={props.n.gates === "red"}>
        <span class={`${CHIP} border-[#5a3424] text-del`} title={`red: ${props.n.redGates.join(", ") || "a gate failed"}`}>
          ✗ {props.n.redGates.join(" · ") || "red"}
        </span>
      </Match>
      <Match when={props.n.gates === "stale"}>
        <span class={`${CHIP} border-gold-deep text-gold-leaf`} title="green for an older tree — the edit since hasn't been gated">◌ stale</span>
      </Match>
      <Match when={props.n.gates === "running"}>
        <span class={`${CHIP} animate-breathe border-rule text-ink-dim motion-reduce:animate-none`}>… gating</span>
      </Match>
      <Match when={props.n.gates === "none"}>
        <span class={`${CHIP} border-rule text-ink-faint`} title="never gated — /push-ready runs them">○ ungated</span>
      </Match>
    </Switch>
  );
}

export function PrChip(props: { n: OutboxNode }) {
  const pr = () => props.n.pr;
  return (
    <Show when={pr()} fallback={
      <span class={`${CHIP} border-transparent text-ink-faint`}>
        {props.n.pushed === "synced" ? "on origin · no PR" : props.n.pushed === "ahead" ? `↑${props.n.ahead} to push` : "local"}
      </span>
    }>
      {(p) => (
        <a
          class={`${CHIP} no-underline ${p().state === "MERGED" ? "border-gold-deep text-gold-deep" : p().review === "APPROVED" ? "border-[#3c4a30] text-add" : "border-[#33463f] text-patina"} hover:border-gold-leaf`}
          href={p().url}
          target="_blank"
          rel="noopener"
          onClick={(e) => e.stopPropagation()}
        >
          #{p().number}
          {p().state === "MERGED" ? " merged" : p().draft ? " draft" : p().review === "APPROVED" ? " ✓ approved" : " in review"}
        </a>
      )}
    </Show>
  );
}

// The landing title, editable in place: what squash-merges onto main, so the one string worth
// fixing before a push. Saves to branch.<b>.stack-pr-title; an emptied field falls back to the
// opening commit's subject.
export function LandingTitle(props: { n: OutboxNode; repo: string; actions: OutboxActions; editing: boolean; setEditing: (on: boolean) => void; class?: string }) {
  const editable = () => canMutate && !props.n.pr;
  let input: HTMLInputElement | undefined;
  createEffect(() => {
    if (props.editing) queueMicrotask(() => { input?.focus(); input?.select(); });
  });
  const save = () => {
    const v = input?.value.trim() ?? "";
    props.setEditing(false);
    if (v !== props.n.title) void props.actions.setTitle(props.repo, props.n.branch, v === props.n.subjects.at(-1) ? "" : v);
  };
  return (
    <Show when={props.editing && editable()} fallback={
      <span
        class={`min-w-0 overflow-hidden text-ellipsis whitespace-nowrap ${editable() ? "cursor-text decoration-gold-deep decoration-dotted underline-offset-4 hover:underline" : ""} ${props.class ?? ""}`}
        title={editable() ? `the PR title that will land — click (or e) to edit${props.n.titleSource === "saved" ? "" : " · from the opening commit"}` : props.n.title}
        onClick={(e) => { if (editable()) { e.stopPropagation(); props.setEditing(true); } }}
      >
        {props.n.title}
        <Show when={props.n.titleSource === "saved"}><span class="ml-[6px] align-[1px] font-mono text-[9px] tracking-[0.1em] text-gold-deep">SET</span></Show>
      </span>
    }>
      <input
        ref={input}
        class="min-w-0 flex-1 rounded-[5px] border border-gold-deep bg-vellum-night px-[6px] py-px font-display text-[15px] text-ink outline-none focus:border-gold-leaf"
        value={props.n.title}
        maxLength={120}
        onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          e.stopPropagation();
          if (e.key === "Enter") save();
          if (e.key === "Escape") props.setEditing(false);
        }}
        onBlur={save}
      />
    </Show>
  );
}

function NodeRow(props: {
  item: Item & { kind: "node" };
  selected: boolean;
  armed: boolean;
  editing: boolean;
  setEditing: (on: boolean) => void;
  actions: OutboxActions;
  onSelect: () => void;
  onOpen: () => void;
  onPush: () => void;
}) {
  const n = () => props.item.node;
  const f = () => props.item.forest;
  const canPush = () => canMutate && !n().pr && n().gates === "green" && n().pushed !== "synced";
  const canOpen = () => !n().pr && n().pushed === "synced" && !!n().compareUrl;
  return (
    <div
      class={`ob-row group relative grid cursor-pointer grid-cols-[22px_1fr_auto] items-start gap-x-[10px] rounded-[9px] border px-[12px] py-[9px] transition-[background,border-color] duration-[120ms] ${props.selected ? "border-gold-deep bg-vellum-edge" : "border-transparent hover:bg-vellum-raise"}`}
      data-key={itemKey(props.item)}
      onClick={props.onSelect}
      onDblClick={props.onOpen}
    >
      <span class={`pt-[3px] text-right font-mono text-[10px] ${props.selected ? "text-gold-leaf" : "text-ink-faint"}`} title={`merge order ${n().position} of ${f().size}`}>
        {f().size > 1 ? `${n().position}/${f().size}` : "·"}
      </span>
      <div class="min-w-0">
        <div class="flex min-w-0 items-baseline gap-[8px]">
          <LandingTitle n={n()} repo={f().repo} actions={props.actions} editing={props.editing} setEditing={props.setEditing}
            class="font-display text-[15.5px] leading-[1.35] text-ink" />
        </div>
        <div class="mt-[3px] flex flex-wrap items-center gap-x-[8px] gap-y-[3px] font-mono text-[11px] text-ink-faint">
          <span class="text-ink-dim">{n().branch}</span>
          <Show when={n().base !== "main"}><span title="stacked base for the PR">→ {n().stackedOn?.pr ? `#${n().stackedOn?.pr}` : n().base}</span></Show>
          <span>{n().commits} commit{n().commits === 1 ? "" : "s"}</span>
          <Show when={!n().pr || n().ahead}><GatesChip n={n()} /></Show>
          <PrChip n={n()} />
        </div>
      </div>
      <div class="flex items-center gap-[6px] pt-[1px]" onClick={(e) => e.stopPropagation()}>
        <Show when={canPush()}>
          <button
            class={props.armed ? BTN_ARMED : BTN_GOLD}
            disabled={props.actions.busy() === "push:" + n().branch}
            title="push to origin (p) — asks once more before it goes"
            onClick={props.onPush}
          >
            {props.actions.busy() === "push:" + n().branch ? "pushing…" : props.armed ? "push to origin?" : "↑ push"}
          </button>
        </Show>
        <Show when={canOpen()}>
          <a class={`${BTN_GOLD} no-underline`} href={n().compareUrl} target="_blank" rel="noopener" title={`open the PR form against ${n().base} (o)`}>open PR ↗</a>
        </Show>
      </div>
    </div>
  );
}

function LaunchCard(props: { item: Item & { kind: "forest" }; selected: boolean; onSelect: () => void; onLaunch: () => void }) {
  const f = () => props.item.forest;
  return (
    <div
      class={`ob-launch relative cursor-pointer rounded-[11px] border px-[14px] py-[11px] transition-[background,border-color] duration-[120ms] ${props.selected ? "border-gold-leaf bg-vellum-edge" : "border-gold-deep bg-vellum-raise hover:border-gold-leaf"}`}
      data-key={itemKey(props.item)}
      onClick={props.onSelect}
      onDblClick={props.onLaunch}
    >
      <div class="flex items-baseline gap-[10px]">
        <span class="font-display text-[19px] italic text-ink">{f().project}</span>
        <Show when={f().ticket}><span class="font-mono text-[10.5px] text-ink-faint">{f().ticket}</span></Show>
        <span class={`font-mono text-[10.5px] ${f().summary === "ready-to-launch" ? "text-add" : "text-gold-leaf"}`}>{summaryLabel[f().summary]}</span>
        <span class="ml-auto font-mono text-[10.5px] text-ink-faint">{f().unopened} of {f().size} not on GitHub</span>
        <button class={BTN_GOLD} title="the launch sheet — push and open every node, top to bottom (l)" onClick={(e) => { e.stopPropagation(); props.onLaunch(); }}>
          launch ⇢
        </button>
      </div>
      <ol class="mt-[8px] mb-0 list-none p-0">
        <For each={f().nodes.filter((n) => n.status !== "empty")}>
          {(n) => (
            <li class="grid grid-cols-[22px_1fr_auto] items-baseline gap-x-[10px] py-[2px]">
              <span class="text-right font-mono text-[10px] text-ink-faint">{n.position}</span>
              <span class={`overflow-hidden text-ellipsis whitespace-nowrap font-display text-[14px] ${n.status === "landed" ? "text-ink-faint line-through decoration-gold-deep" : "text-ink-dim"}`} title={n.branch}>{n.title}</span>
              <span class="flex gap-[6px]"><Show when={!n.pr}><GatesChip n={n} /></Show><PrChip n={n} /></span>
            </li>
          )}
        </For>
      </ol>
    </div>
  );
}

export function Outbox() {
  const { location, navigate } = useViewerLocation();
  const actions = useOutboxActions();
  const outbox = createQuery(() => ({
    queryKey: ["outbox", ""],
    queryFn: () => fetchOutbox(),
    refetchInterval: 30_000,
  }));
  const items = createMemo(() => laneItems(outbox.data));
  const [cursor, setCursor] = createSignal<string | null>(null);
  const [armed, setArmed] = createSignal<string | null>(null);
  const [editing, setEditing] = createSignal<string | null>(null);
  const current = createMemo(() => items().find((i) => itemKey(i) === cursor()) ?? items()[0]);
  const laneOf = (lane: Lane) => items().filter((i) => i.lane === lane);

  const select = (it: Item) => {
    setCursor(itemKey(it));
    if (armed() !== itemKey(it)) setArmed(null);
  };
  const move = (d: number) => {
    const all = items();
    if (!all.length) return;
    const at = Math.max(0, all.findIndex((i) => itemKey(i) === itemKey(current()!)));
    const next = all[Math.min(all.length - 1, Math.max(0, at + d))];
    select(next);
    document.querySelector(`[data-key="${CSS.escape(itemKey(next))}"]`)?.scrollIntoView({ block: "nearest" });
  };
  const openNode = (f: OutboxForest, n: OutboxNode) =>
    navigate({ kind: "forest", name: f.project, node: n.branch, repo: f.repo === "loops" ? undefined : f.repo });
  const launch = (f: OutboxForest) => navigate({ kind: "outbox", launch: f.project, repo: f.repo === "loops" ? undefined : f.repo });
  const pushItem = (it: Item) => {
    if (it.kind !== "node") return;
    const n = it.node;
    if (!canMutate || n.pr || n.gates !== "green" || n.pushed === "synced") return;
    const key = itemKey(it);
    if (armed() !== key) {
      setArmed(key);
      return;
    }
    setArmed(null);
    void actions.push(it.forest.repo, n.branch, n.compareUrl);
  };

  const onKey = (e: KeyboardEvent) => {
    const loc = location();
    if (loc.kind !== "outbox" || loc.launch) return;
    const t = e.target as HTMLElement | null;
    if (e.metaKey || e.ctrlKey || e.altKey || (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable))) return;
    const it = current();
    if (e.key === "j" || e.key === "ArrowDown") { e.preventDefault(); move(1); }
    else if (e.key === "k" || e.key === "ArrowUp") { e.preventDefault(); move(-1); }
    else if (e.key === "Escape") setArmed(null);
    else if (!it) return;
    else if (e.key === "Enter") {
      e.preventDefault();
      if (armed() === itemKey(it)) pushItem(it);
      else if (it.kind === "forest") launch(it.forest);
      else openNode(it.forest, it.node);
    }
    else if (e.key === "p") { e.preventDefault(); pushItem(it); }
    else if (e.key === "l") { e.preventDefault(); launch(it.forest); }
    else if (e.key === "e" && it.kind === "node") { e.preventDefault(); setEditing(itemKey(it)); }
    else if (e.key === "o" && it.kind === "node" && it.node.compareUrl && it.node.pushed === "synced") window.open(it.node.compareUrl, "_blank", "noopener");
  };
  window.addEventListener("keydown", onKey);
  onCleanup(() => window.removeEventListener("keydown", onKey));

  const counts = createMemo(() => {
    const c = (l: Lane) => laneOf(l).length;
    return [
      c("ready") && `${c("ready")} ready`,
      c("launch") && `${c("launch")} forest${c("launch") === 1 ? "" : "s"} to launch`,
      c("approved") && `${c("approved")} approved, waiting`,
      c("work") && `${c("work")} need work`,
    ].filter(Boolean).join(" · ");
  });

  const laneBody = (lane: Lane): JSX.Element => (
    <For each={laneOf(lane)}>
      {(it) => (
        <Show when={it.kind === "node" ? it : null} fallback={
          <LaunchCard item={it as Item & { kind: "forest" }} selected={itemKey(current()!) === itemKey(it)} onSelect={() => select(it)} onLaunch={() => launch(it.forest)} />
        }>
          {(nit) => (
            <NodeRow
              item={nit()}
              selected={!!current() && itemKey(current()!) === itemKey(it)}
              armed={armed() === itemKey(it)}
              editing={editing() === itemKey(it)}
              setEditing={(on) => setEditing(on ? itemKey(it) : null)}
              actions={actions}
              onSelect={() => select(it)}
              onOpen={() => openNode(it.forest, nit().node)}
              onPush={() => { select(it); pushItem(it); }}
            />
          )}
        </Show>
      )}
    </For>
  );

  return (
    <div class="ledger min-h-screen">
      <main class="mx-auto w-full max-w-[860px] px-[28px] pt-[30px] pb-[120px] max-[640px]:px-[16px]">
        <header class="mb-[18px] flex items-baseline justify-between gap-4">
          <h1 class="m-0 font-display text-[26px] font-semibold italic text-ink">
            <span class="mr-[6px] text-[13px] not-italic text-gold-leaf">✦</span>outbox
          </h1>
          <span class="font-mono text-[11px] text-ink-faint">{counts()}</span>
        </header>

        <Show when={outbox.data} fallback={<p class="font-display italic text-ink-dim">{outbox.isError ? "the outbox didn't load — is the server up?" : "reading every forest…"}</p>}>
          <Show when={items().length} fallback={<p class="mt-[40px] font-display text-[18px] italic text-ink-dim">Nothing unlanded. The outbox is empty.</p>}>
            <For each={LANES.filter((l) => laneOf(l.id).length)}>
              {(l) => (
                <section class={`ob-lane mb-[22px] ob-lane-${l.id}`}>
                  <h2 class={`${EYEBROW} mt-[26px] mb-[8px]`}>
                    {l.title}
                    <span class={ASK}>— {l.ask}</span>
                  </h2>
                  <div class="mb-[6px] h-px bg-rule" />
                  <div class="flex flex-col gap-[4px]">{laneBody(l.id)}</div>
                </section>
              )}
            </For>
          </Show>
          <p class="mt-[40px] font-mono text-[10.5px] text-ink-faint">
            j/k move · ↵ open · p push · e edit title · o open PR · l launch sheet
            <Show when={outbox.data?.prSource === "fixture"}> · PR state from fixture</Show>
          </p>
        </Show>

        <Show when={actions.flash()}>
          {(fl) => (
            <div class={`fixed bottom-[26px] left-1/2 z-[250] flex max-w-[min(90vw,680px)] -translate-x-1/2 items-baseline gap-3 rounded-[9px] border bg-vellum-raise px-4 py-[9px] text-[12px] shadow-[0_14px_40px_#0009] ${fl().ok ? "border-gold-deep text-ink" : "border-del text-del"}`}>
              <span>{fl().text}</span>
              <Show when={fl().link}><a class="font-mono text-gold-leaf" href={fl().link} target="_blank" rel="noopener">open PR ↗</a></Show>
            </div>
          )}
        </Show>
      </main>
    </div>
  );
}

