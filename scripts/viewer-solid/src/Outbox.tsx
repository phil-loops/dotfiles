// The outbox — the landing page, built around shipping. Four months of telemetry say the home page
// was a 3-second pass-through on the way to fix-the-words-then-push, and GitHub says the time goes
// before the push, in forests that drain one PR at a time. So home is now every unlanded branch,
// lane by lane, each row carrying the title that will land and the one action it's waiting for.
import { createMemo, createSignal, For, onCleanup, Show, type JSX } from "solid-js";
import { createQuery } from "@tanstack/solid-query";
import { useViewerLocation } from "./router";
import { canMutate } from "./provider";
import { fetchOutbox, useOutboxActions, type OutboxActions } from "./outboxActions";
import { GatesChip, LandingTitle, PrChip } from "./OutboxParts";
import { LaunchSheet } from "./LaunchSheet";
import { PushWindow } from "./PushWindow";
import {
  LANES, laneItems, itemKey, summaryLabel, clockNow, isDue, isHeld, nextMorning, fmtDayPT, pushWindow,
  type Item, type Lane, type OutboxForest, type OutboxNode, type Waiting,
} from "./outboxModel";

const EYEBROW = "eyebrow text-[10px] font-medium tracking-[0.22em] uppercase text-ink-faint";
const ASK = "ml-2 font-display text-[14px] normal-case italic tracking-normal text-ink-dim";
const BTN = "flex-none cursor-pointer rounded-[7px] border px-[11px] py-[3px] font-mono text-[11px] leading-[1.55] tracking-[0.02em] transition-[border-color,color,background] duration-[120ms] disabled:cursor-default disabled:opacity-45";
const BTN_GOLD = `${BTN} border-gold-deep text-gold-leaf hover:bg-gold-wash enabled:hover:border-gold-leaf`;
const BTN_QUIET = `${BTN} border-rule text-ink-dim hover:border-gold-deep hover:text-gold-leaf`;
const BTN_ARMED = `${BTN} border-gold-leaf bg-gold-leaf text-vellum-night`;

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
  onHold: () => void;
  now: number;
}) {
  const n = () => props.item.node;
  const held = () => isHeld(n());
  const due = () => isDue(n(), props.now);
  const f = () => props.item.forest;
  const canPush = () => canMutate && !n().pr && n().gates === "green" && n().pushed !== "synced";
  const canOpen = () => !n().pr && n().pushed === "synced" && !!n().compareUrl;
  return (
    <div
      class={`ob-row group relative grid cursor-pointer grid-cols-[22px_1fr_auto] items-start gap-x-[10px] rounded-[9px] border px-[12px] py-[9px] transition-[background,border-color] duration-[120ms] ${props.selected ? "border-gold-deep bg-vellum-edge" : "border-transparent hover:bg-vellum-raise"} ${due() ? "shadow-[inset_2px_0_0_var(--color-gold-leaf)]" : held() ? "opacity-75" : ""}`}
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
          <Show when={n().status === "review" && n().pr?.createdAt}>
            <span title={n().pr?.createdAt}>opened {fmtAge(n().pr?.createdAt)} ago</span>
          </Show>
          <Show when={held()}>
            <span class={due() ? "text-gold-leaf" : "text-ink-faint"} title={n().holdUntil}>
              {due() ? "☀ due now" : `☾ held until ${fmtDayPT(Date.parse(n().holdUntil))}`}
            </span>
          </Show>
        </div>
        <Show when={n().status === "approved" && n().waitingOn?.length}>
          <ApprovedWait n={n()} />
        </Show>
      </div>
      <div class="flex items-center gap-[6px] pt-[1px]" onClick={(e) => e.stopPropagation()}>
        <Show when={canMutate && !n().pr}>
          <button
            class={`${BTN} border-transparent text-ink-faint opacity-0 group-hover:opacity-100 hover:border-rule hover:text-ink-dim ${props.selected || held() ? "opacity-100" : ""}`}
            disabled={props.actions.busy() === "hold:" + n().branch}
            title={held() ? "release the hold (h)" : "hold for the morning push (h) — moves it to the first-thing lane; nothing pushes by itself"}
            onClick={props.onHold}
          >
            {held() ? "☀ release" : "☾ hold"}
          </button>
        </Show>
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

const fmtAge = (iso?: string): string => {
  const t = iso ? Date.parse(iso) : NaN;
  if (!Number.isFinite(t)) return "?";
  const h = Math.max(0, (Date.now() - t) / 3_600_000);
  return h < 1 ? `${Math.round(h * 60)}m` : h < 48 ? `${Math.round(h)}h` : `${Math.round(h / 24)}d`;
};

const WAIT_TONE: Record<Waiting["kind"], string> = {
  merge: "border-[#3c4a30] text-add",
  parent: "border-gold-deep text-gold-leaf",
  ci: "border-[#5a3424] text-del",
  conflicts: "border-[#5a3424] text-del",
  behind: "border-gold-deep text-gold-leaf",
  checks: "border-rule text-ink-dim",
  draft: "border-rule text-ink-dim",
};

// An approved PR's tail: how long it's sat approved, and each thing it waits on as a link to the
// one human action that clears it — the parent's PR, the failing checks, the conflict. The first
// is the next move; nothing here merges.
function ApprovedWait(props: { n: OutboxNode }) {
  const pr = () => props.n.pr!;
  return (
    <div class="mt-[6px] flex flex-wrap items-center gap-[6px] font-mono text-[11px]">
      <span class="text-ink-faint" title={pr().approvedAt || ""}>
        approved {props.n.waitingH != null ? `${Math.round(props.n.waitingH)}h` : "?"} ago
        {pr().approvals ? ` · ${pr().approvals} approval${pr().approvals === 1 ? "" : "s"}` : ""} · waiting on
      </span>
      <For each={props.n.waitingOn}>
        {(w, i) => (
          <a
            class={`${CHIP_W} no-underline ${WAIT_TONE[w.kind]} ${i() === 0 ? "shadow-[0_0_0_1px_rgba(230,182,78,0.15)]" : "opacity-80"} hover:opacity-100`}
            href={w.url || undefined}
            target="_blank"
            rel="noopener"
            title={i() === 0 ? "the next human action" : ""}
            onClick={(e) => e.stopPropagation()}
          >
            {i() === 0 ? "→ " : ""}{w.label}{w.url ? " ↗" : ""}
          </a>
        )}
      </For>
    </div>
  );
}

const CHIP_W = "inline-flex items-center rounded-[6px] border px-[7px] py-px leading-[1.6] whitespace-nowrap";

function LaunchCard(props: { item: Item & { kind: "forest" }; selected: boolean; onSelect: () => void; onLaunch: () => void; onHold: () => void }) {
  const f = () => props.item.forest;
  const held = () => f().nodes.some((n) => isHeld(n));
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
        <Show when={canMutate}>
          <button class={`${BTN} border-transparent text-ink-faint hover:border-rule hover:text-ink-dim`} title={held() ? "release the forest's hold (h)" : "hold the whole forest for the morning launch (h)"}
            onClick={(e) => { e.stopPropagation(); props.onHold(); }}>
            {held() ? "☀ release" : "☾ hold forest"}
          </button>
        </Show>
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
  const laneOf = (lane: Lane) => items().filter((i) => i.lane === lane);
  const [now, setNow] = createSignal(clockNow());
  const tick = setInterval(() => setNow(clockNow()), 30_000);
  onCleanup(() => clearInterval(tick));
  const morningIso = () => new Date(nextMorning(now(), outbox.data?.window.morningHourPT ?? 9)).toISOString();
  const allNodes = createMemo(() => (outbox.data?.forests ?? []).flatMap((f) => f.nodes.map((n) => ({ f, n }))));
  const due = createMemo(() => allNodes().filter(({ n }) => isDue(n, now())).length);
  const holdable = createMemo(() => allNodes().filter(({ n }) => n.status === "ready" && !n.holdUntil));
  const holdAll = () => {
    const until = morningIso();
    const byRepo = new Map<string, string[]>();
    for (const { f, n } of holdable()) byRepo.set(f.repo, [...(byRepo.get(f.repo) ?? []), n.branch]);
    for (const [repo, branches] of byRepo) void actions.hold(repo, { branches }, until);
  };
  const toggleHold = (it: Item) => {
    if (!canMutate) return;
    if (it.kind === "forest") {
      const on = it.forest.nodes.some((n) => isHeld(n));
      void actions.hold(it.forest.repo, { project: it.forest.project }, on ? "" : morningIso());
    } else if (!it.node.pr) {
      void actions.hold(it.forest.repo, { branch: it.node.branch }, isHeld(it.node) ? "" : morningIso());
    }
  };
  // bet 3's own measure: approved-but-unmerged hours, summed — the p90 tail is 78h
  const approvedAsk = createMemo(() => {
    const hrs = laneOf("approved").reduce((a, it) => a + (it.kind === "node" ? it.node.waitingH ?? 0 : 0), 0);
    return `${Math.round(hrs)}h approved-but-unmerged between them; the next human action for each`;
  });
  const firstLane = createMemo(() => {
    const held = laneOf("first");
    const anyDue = held.some((it) => it.kind === "node" ? isDue(it.node, now()) : it.forest.nodes.some((n) => isDue(n, now())));
    const until = held.map((it) => it.kind === "node" ? it.node.holdUntil : it.forest.nodes.find((n) => n.holdUntil)?.holdUntil ?? "").find(Boolean);
    return anyDue
      ? { title: "first thing — it's morning", ask: "held overnight, due now: push these while the window's open" }
      : { title: "first thing tomorrow", ask: until ? `held until ${fmtDayPT(Date.parse(until))} — nothing pushes by itself` : "held for the morning push" };
  });
  const sheet = createMemo(() => {
    const l = location();
    return l.kind === "outbox" && l.launch ? { project: l.launch, repo: l.repo } : null;
  });
  const [cursor, setCursor] = createSignal<string | null>(null);
  const [armed, setArmed] = createSignal<string | null>(null);
  const [editing, setEditing] = createSignal<string | null>(null);
  const current = createMemo(() => items().find((i) => itemKey(i) === cursor()) ?? items()[0]);

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
    else if (e.key === "h") { e.preventDefault(); toggleHold(it); }
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
          <LaunchCard item={it as Item & { kind: "forest" }} selected={itemKey(current()!) === itemKey(it)} onSelect={() => select(it)} onLaunch={() => launch(it.forest)} onHold={() => toggleHold(it)} />
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
              onHold={() => toggleHold(it)}
              now={now()}
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

        <Show when={outbox.data}>
          {(d) => <PushWindow facts={d().window} now={now()} holdable={holdable().length} due={due()} onHoldAll={canMutate ? holdAll : undefined} />}
        </Show>

        <Show when={outbox.data} fallback={<p class="font-display italic text-ink-dim">{outbox.isError ? "the outbox didn't load — is the server up?" : "reading every forest…"}</p>}>
          <Show when={items().length} fallback={<p class="mt-[40px] font-display text-[18px] italic text-ink-dim">Nothing unlanded. The outbox is empty.</p>}>
            <For each={LANES.filter((l) => laneOf(l.id).length)}>
              {(l) => (
                <section class={`ob-lane mb-[22px] ob-lane-${l.id}`}>
                  <h2 class={`${EYEBROW} mt-[26px] mb-[8px] ${l.id === "first" && due() ? "text-gold-leaf" : ""}`}>
                    {l.id === "first" ? firstLane().title : l.title}
                    <span class={ASK}>— {l.id === "first" ? firstLane().ask : l.id === "approved" ? approvedAsk() : l.ask}</span>
                  </h2>
                  <div class="mb-[6px] h-px bg-rule" />
                  <div class="flex flex-col gap-[4px]">{laneBody(l.id)}</div>
                </section>
              )}
            </For>
          </Show>
          <p class="mt-[40px] font-mono text-[10.5px] text-ink-faint">
            j/k move · ↵ open · p push · h hold · e edit title · o open PR · l launch sheet
            <Show when={outbox.data?.prSource === "fixture"}> · PR state from fixture</Show>
          </p>
        </Show>

        <Show when={sheet()}>
          {(sh) => (
            <LaunchSheet
              project={sh().project}
              repo={sh().repo}
              actions={actions}
              window={outbox.data?.window}
              banner={() => {
                const d = outbox.data;
                if (!d) return null;
                const ph = pushWindow(now(), d.window).phase;
                return ph === "late" || ph === "weekend" || ph === "closing"
                  ? <div class="mt-[14px]"><PushWindow facts={d.window} now={now()} holdable={0} due={0} compact /></div>
                  : null;
              }}
              onHold={() => {
                const f = outbox.data?.forests.find((x) => x.project === sh().project && (!sh().repo || x.repo === sh().repo));
                if (f) toggleHold({ kind: "forest", lane: "launch", forest: f });
              }}
              onClose={() => navigate({ kind: "outbox" })}
              onOpenNode={(n) => navigate({ kind: "forest", name: sh().project, node: n.branch, repo: sh().repo })}
            />
          )}
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

