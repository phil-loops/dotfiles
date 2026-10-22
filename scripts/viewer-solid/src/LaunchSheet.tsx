// The launch sheet: a whole forest onto GitHub in one sitting. Every node top to bottom in merge
// order, each with two steps — push (Phil's click, through /push-origin) and open the PR (a link
// to the compare form, base and title and body prefilled). Nothing here opens a PR or pushes on
// its own; the sheet only makes each step one click and ticks it off as the cached PR state sees it.
import { createMemo, createSignal, For, onCleanup, Show, type JSX } from "solid-js";
import { createQuery } from "@tanstack/solid-query";
import { canMutate } from "./provider";
import { fetchOutbox, type OutboxActions } from "./outboxActions";
import { launchSteps, type OutboxNode, type Step, type PushWindowFacts } from "./outboxModel";
import { GatesChip, LandingTitle, PacketChips, PrChip } from "./OutboxParts";

const STEP: Record<Step, string> = {
  done: "border-gold-deep bg-gold-deep/40 text-gold-leaf",
  now: "border-gold-leaf text-gold-leaf",
  waiting: "border-rule text-ink-faint",
  blocked: "border-[#5a3424] text-del",
};
const BTN = "cursor-pointer rounded-[7px] border px-[11px] py-[3px] font-mono text-[11px] leading-[1.55] no-underline transition-[border-color,color,background] duration-[120ms] disabled:cursor-default disabled:opacity-45";

export function LaunchSheet(props: {
  project: string;
  repo?: string;
  actions: OutboxActions;
  window?: PushWindowFacts;
  banner?: () => JSX.Element;
  onHold?: () => void;
  onClose: () => void;
  onOpenNode: (n: OutboxNode) => void;
}) {
  const q = createQuery(() => ({
    queryKey: ["outbox", (props.repo ?? "") + "/" + props.project],
    queryFn: () => fetchOutbox(props.project, props.repo),
    refetchInterval: 4_000,
  }));
  const forest = createMemo(() => q.data?.forests[0]);
  const nodes = createMemo(() => (forest()?.nodes ?? []).filter((n) => n.status !== "empty"));
  const byBranch = createMemo(() => new Map(nodes().map((n) => [n.branch, n])));
  const steps = (n: OutboxNode) => launchSteps(n, byBranch().get(n.parent));
  const onGitHub = createMemo(() => nodes().filter((n) => !!n.pr).length);
  const [cursor, setCursor] = createSignal(0);
  const [armed, setArmed] = createSignal<string | null>(null);
  const [editing, setEditing] = createSignal<string | null>(null);
  // compare forms Phil opened from here, so the step reads "waiting for GitHub" until the PR shows
  const [opened, setOpened] = createSignal<Set<string>>(new Set());
  const markOpened = (b: string) => setOpened((s) => new Set(s).add(b));

  const push = (n: OutboxNode) => {
    if (!canMutate || steps(n).push !== "now" && steps(n).push !== "waiting") return;
    if (n.gates !== "green") return;
    if (armed() !== n.branch) {
      setArmed(n.branch);
      return;
    }
    setArmed(null);
    void props.actions.push(forest()!.repo, n.branch, n.compareUrl).then(() => q.refetch());
  };
  const open = (n: OutboxNode) => {
    if (steps(n).open !== "now" || !n.compareUrl) return;
    markOpened(n.branch);
    window.open(n.compareUrl, "_blank", "noopener");
  };

  const onKey = (e: KeyboardEvent) => {
    const t = e.target as HTMLElement | null;
    if (e.metaKey || e.ctrlKey || e.altKey || (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA"))) return;
    const n = nodes()[cursor()];
    if (e.key === "Escape") { e.preventDefault(); if (armed()) setArmed(null); else props.onClose(); }
    else if (e.key === "j" || e.key === "ArrowDown") { e.preventDefault(); setCursor((c) => Math.min(nodes().length - 1, c + 1)); setArmed(null); }
    else if (e.key === "k" || e.key === "ArrowUp") { e.preventDefault(); setCursor((c) => Math.max(0, c - 1)); setArmed(null); }
    else if (!n) return;
    else if (e.key === "p") { e.preventDefault(); push(n); }
    else if (e.key === "Enter" && armed() === n.branch) { e.preventDefault(); push(n); }
    else if (e.key === "o") { e.preventDefault(); open(n); }
    else if (e.key === "e") { e.preventDefault(); setEditing(n.branch); }
    else if (e.key === "h") { e.preventDefault(); props.onHold?.(); }
    else if (e.key === "Enter") { e.preventDefault(); props.onOpenNode(n); }
  };
  window.addEventListener("keydown", onKey, true);
  onCleanup(() => window.removeEventListener("keydown", onKey, true));

  const stepPill = (label: string, s: Step, extra?: string) => (
    <span class={`inline-flex items-center gap-[5px] rounded-full border px-[9px] py-px font-mono text-[10.5px] leading-[1.7] ${STEP[s]}`}>
      {s === "done" ? "✓" : s === "blocked" ? "✗" : s === "now" ? "●" : "○"} {label}{extra ? ` ${extra}` : ""}
    </span>
  );

  return (
    <div class="fixed inset-0 z-[120] flex items-start justify-center overflow-y-auto bg-[rgba(8,6,3,0.72)] px-[16px] pt-[6vh] pb-[40px] backdrop-blur-[2px]" onClick={props.onClose}>
      <div
        class="ob-sheet w-full max-w-[820px] rounded-[14px] border border-gold-deep bg-vellum-night shadow-[0_30px_80px_rgba(0,0,0,0.6)]"
        onClick={(e) => e.stopPropagation()}
      >
        <Show when={forest()} fallback={
          <div class="p-[28px] font-display italic text-ink-dim">{q.isLoading ? "reading the forest…" : `${props.project} has nothing left to launch.`}</div>
        }>
          {(f) => (
            <>
              <header class="border-b border-rule px-[26px] pt-[22px] pb-[16px]">
                <div class="flex items-baseline gap-[12px]">
                  <span class="font-mono text-[10px] tracking-[0.22em] text-ink-faint uppercase">launch</span>
                  <h2 class="m-0 font-display text-[28px] font-semibold italic text-ink">{f().project}</h2>
                  <Show when={f().ticket}><span class="font-mono text-[11px] text-ink-faint">{f().ticket}</span></Show>
                  <button class="ml-auto cursor-pointer font-mono text-[11px] text-ink-faint hover:text-gold-leaf" onClick={props.onClose}>esc ✕</button>
                </div>
                <p class="mt-[8px] mb-0 max-w-[640px] font-display text-[14px] leading-[1.5] text-ink-dim italic">
                  Open every node now, stacked on its parent's PR, so the reviews overlap. Drained one merge at a time,
                  a forest has taken a median {props.window?.serialForestH ?? 164}h first-open → last-merge — about a week.
                </p>
                <div class="mt-[14px] flex items-center gap-[12px]">
                  <div class="h-[5px] flex-1 overflow-hidden rounded-full bg-vellum-edge">
                    <div class="h-full rounded-full bg-gold-leaf transition-[width] duration-500" style={{ width: `${(100 * onGitHub()) / Math.max(1, nodes().length)}%` }} />
                  </div>
                  <span class="font-mono text-[11px] text-ink-dim">{onGitHub()} of {nodes().length} on GitHub</span>
                  <Show when={canMutate && props.onHold && onGitHub() < nodes().length}>
                    <button class={`${BTN} border-rule text-ink-dim hover:border-gold-deep hover:text-gold-leaf`} title="hold the forest for the morning launch (h)" onClick={() => props.onHold?.()}>
                      {nodes().some((n) => n.holdUntil && !n.pr) ? "☀ release hold" : "☾ hold for morning"}
                    </button>
                  </Show>
                </div>
                {props.banner?.()}
              </header>

              <ol class="m-0 list-none px-[14px] py-[10px]">
                <For each={nodes()}>
                  {(n, i) => {
                    const st = () => steps(n);
                    const sel = () => cursor() === i();
                    return (
                      <li
                        class={`ob-step grid cursor-pointer grid-cols-[34px_1fr] gap-x-[10px] rounded-[10px] border px-[12px] py-[11px] ${sel() ? "border-gold-deep bg-vellum-edge" : "border-transparent"}`}
                        onClick={() => setCursor(i())}
                      >
                        <span class={`pt-[1px] text-center font-display text-[22px] italic leading-none ${n.pr ? "text-gold-deep" : sel() ? "text-gold-leaf" : "text-ink-faint"}`}>{n.position}</span>
                        <div class="min-w-0">
                          <div class="flex min-w-0 items-baseline gap-[8px]">
                            <LandingTitle n={n} repo={f().repo} actions={props.actions} editing={editing() === n.branch}
                              setEditing={(on) => setEditing(on ? n.branch : null)}
                              class={`font-display text-[16px] ${n.status === "landed" ? "text-ink-faint line-through decoration-gold-deep" : "text-ink"}`} />
                          </div>
                          <div class="mt-[3px] flex flex-wrap items-center gap-x-[8px] gap-y-[3px] font-mono text-[11px] text-ink-faint">
                            <span class="text-ink-dim">{n.branch}</span>
                            <span title="the PR's base — the parent's branch while it's unmerged, so the review diff is this node's own work">
                              base {n.base}{n.stackedOn?.pr ? ` (#${n.stackedOn.pr})` : ""}
                            </span>
                            <span>{n.commits} commit{n.commits === 1 ? "" : "s"}</span>
                            <Show when={!n.pr}><GatesChip n={n} /></Show>
                            <PrChip n={n} />
                            <PacketChips n={n} />
                          </div>
                          <div class="mt-[8px] flex flex-wrap items-center gap-[8px]">
                            {stepPill("push", st().push, n.pushed === "ahead" ? `↑${n.ahead}` : "")}
                            <span class="text-[10px] text-ink-faint">⟶</span>
                            {stepPill("open PR", n.pr ? "done" : opened().has(n.branch) && st().open === "now" ? "now" : st().open,
                              n.pr ? `#${n.pr.number}` : opened().has(n.branch) ? "— waiting for GitHub…" : "")}
                            <span class="ml-auto flex gap-[6px]">
                              <Show when={canMutate && !n.pr && n.pushed !== "synced"}>
                                <button
                                  class={`${BTN} ${armed() === n.branch ? "border-gold-leaf bg-gold-leaf text-vellum-night" : st().push === "now" ? "border-gold-leaf text-gold-leaf hover:bg-gold-wash" : n.gates === "green" ? "border-rule text-ink-dim hover:border-gold-deep" : "border-rule text-ink-faint"}`}
                                  disabled={n.gates !== "green" || props.actions.busy() === "push:" + n.branch}
                                  title={n.gates !== "green" ? "gates aren't green for this tree — /push-ready first" : st().push === "waiting" ? "its parent isn't on origin yet — push top to bottom" : "push to origin (p)"}
                                  onClick={(e) => { e.stopPropagation(); setCursor(i()); push(n); }}
                                >
                                  {props.actions.busy() === "push:" + n.branch ? "pushing…" : armed() === n.branch ? "push to origin?" : "↑ push"}
                                </button>
                              </Show>
                              <Show when={!n.pr && n.compareUrl && canMutate}>
                                <button
                                  class={`${BTN} border-transparent ${n.label ? "text-patina" : "text-ink-faint"} hover:border-rule`}
                                  title={n.label ? "the PR opens labelled ai-code-review: the bot reviews once, checking the diff against the packet's Intent — click to drop it" : "no review label — click to ask the bot to check this PR's claims"}
                                  onClick={(e) => { e.stopPropagation(); void props.actions.setLabel(forest()!.repo, n.branch, !n.label).then(() => q.refetch()); }}
                                >{n.label ? "◉" : "○"} ai review</button>
                              </Show>
                              <Show when={!n.pr && n.compareUrl}>
                                <a
                                  class={`${BTN} ${st().open === "now" ? "border-gold-leaf text-gold-leaf hover:bg-gold-wash" : "pointer-events-none border-rule text-ink-faint opacity-50"}`}
                                  href={n.compareUrl}
                                  target="_blank"
                                  rel="noopener"
                                  title={`compare ${n.base}...${n.branch}, title + review packet${n.label ? " + ai-code-review label" : ""} prefilled (o)`}
                                  onClick={(e) => { e.stopPropagation(); markOpened(n.branch); }}
                                >
                                  open PR ↗
                                </a>
                              </Show>
                            </span>
                          </div>
                        </div>
                      </li>
                    );
                  }}
                </For>
              </ol>
              <footer class="flex items-baseline justify-between border-t border-rule px-[26px] py-[12px] font-mono text-[10.5px] text-ink-faint">
                <span>j/k move · p push · o open PR · e edit title · h hold · ↵ open node · esc close</span>
                <Show when={onGitHub() === nodes().length && nodes().length}>
                  <span class="font-display text-[14px] italic text-gold-leaf">✦ the whole forest is on GitHub</span>
                </Show>
              </footer>
            </>
          )}
        </Show>
      </div>
    </div>
  );
}
