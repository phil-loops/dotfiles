import { Show, Switch, Match } from "solid-js";
import { Link } from "./router";
import { deleteMode } from "./deleteMode";
import { canMutate } from "./provider";
import { ActionBar, type Action } from "./actions";
import { leaf, mergedAgo, interestPips } from "./shared";
import type { NextStep } from "./homeModel";
import type { Project, Parked, PR } from "./types";

// one forest row, shared by the priority tiers and the recently-merged fold. Metadata sits in
// fixed-width cells (name · chat · status) so the columns line up; `folded` rows swap the
// behind/restack trail for a static ✨-merged badge.
export function ForestRow(props: {
  p: Project;
  folded: boolean;
  parked: () => Parked | null;
  menu: () => string | null;
  setMenu: (v: string | null) => void;
  showFtip: (project: string, el: HTMLElement, repo?: string, landed?: Project["landed"]) => void;
  hideFtip: () => void;
  onContext: (e: MouseEvent, p: Project) => void;
  hasLiveChat: (p: Project) => boolean;
  prOf: (name: string) => PR | undefined;
  dropAction: (p: Project) => Action;
  resolve: (name: string) => void;
  abort: (name: string) => void;
  next?: { step: NextStep; start: boolean };
}) {
  const stuck = () => props.parked()?.project === props.p.name;
  const ROW =
    "forest-row group mb-[6px] flex items-center gap-[11px] rounded-[10px] border bg-vellum-raise px-[15px] py-[11px] text-ink no-underline transition-[border-color,background,transform] duration-[120ms] hover:-translate-y-px hover:bg-vellum-edge [.epic-subrow_&]:mb-0 [.epic-subrow_&]:flex-1";
  const DOT = "h-2 w-2 flex-none rounded-full";
  const POP_BTN =
    "cursor-pointer rounded-[6px] border px-[9px] py-[5px] text-left text-[11px] leading-[1.55] tracking-[0.02em] transition-[border-color,color,background] duration-[120ms]";
  return (
    <Link
      class={`${ROW} ${stuck() ? "border-del" : "border-rule hover:border-gold-deep"} ${
        props.folded ? "opacity-[0.66] hover:opacity-100" : ""
      }`}
      classList={{ parked: stuck(), folded: props.folded }}
      to={{
        kind: "forest",
        name: props.p.name,
        repo: props.p.repo,
        node: props.p.repo !== "loops" ? (props.p.mergeable?.[0] ?? props.p.candidates?.[0]) : undefined,
      }}
      onMouseEnter={(e) => props.showFtip(props.p.name, e.currentTarget as HTMLElement, props.p.repo, props.p.landed)}
      onMouseLeave={props.hideFtip}
      onContextMenu={(e) => props.onContext(e, props.p)}
    >
      <span
        class={`forest-dot ${DOT} ${
          stuck()
            ? "parked border-[1.5px] border-solid border-del shadow-[inset_0_0_0_1.5px_var(--color-del)]"
            : props.p.behind > 0
              ? "behind border-[1.5px] border-solid border-patina shadow-[inset_0_0_0_1.5px_var(--color-patina)]"
              : "fresh bg-gold-leaf shadow-[0_0_7px_var(--color-gold-wash)]"
        }`}
      />
      <span class="forest-name flex-1 font-display text-[17px] italic">{props.p.name}</span>
      {/* interest pips demoted to passive metadata — lifecycle bands order the page now */}
      <Show when={(props.p.interest ?? 0) > 0}>
        <span class="forest-pips mr-2 flex-none text-[10px] tracking-[0.14em] text-ink-faint">{interestPips(props.p.interest!)}</span>
      </Show>
      <Show when={props.hasLiveChat(props.p)}>
        <span class="forest-chat flex-none text-gold-leaf animate-chat-pulse-slow motion-reduce:animate-none" title="a chat is running on this forest">✦</span>
      </Show>
      {/* ONE status cell, by precedence (Phil, strike 5: "a row = name + one signal") —
          drop-mode > parked repair > merged fold > behind count > open PR. Pips sit dim
          after the name, node count on the overview; no signal at all = fresh. */}
      <span class="fcell trail ml-auto flex flex-none items-center justify-end text-right text-[11px] text-ink-faint">
        <Switch
          fallback={
            <Show when={props.prOf(props.p.name)}>
              {(pr) => (
                <span
                  class={`forest-pr flex-none rounded-full border border-solid border-rule px-[7px] py-px text-[10px] uppercase tracking-[0.06em] ${pr().draft ? "text-ink-faint" : "text-ink-dim"}`}
                  classList={{ draft: pr().draft }}
                  title={pr().title}
                >
                  {pr().draft ? "draft" : "PR"} #{pr().num}
                </span>
              )}
            </Show>
          }
        >
          <Match when={deleteMode() && canMutate}>
            <ActionBar actions={[props.dropAction(props.p)]} />
          </Match>
          <Match when={stuck()}>
            <div class="forest-parked relative flex-none">
              <button
                class={`forest-resolve flex-none cursor-pointer rounded-[7px] border border-del px-[11px] py-[3px] text-[11px] leading-[1.55] tracking-[0.03em] transition-[border-color,color,background] duration-[120ms] motion-safe:animate-pulse-resolve ${
                  props.menu() === props.p.name ? "bg-del text-[#1a1411]" : "bg-del-bg text-del"
                }`}
                classList={{ open: props.menu() === props.p.name }}
                onClick={(e) => { e.preventDefault(); e.stopPropagation(); props.setMenu(props.menu() === props.p.name ? null : props.p.name); }}
              >
                ⚠ parked at {leaf(props.parked()?.current || props.p.name)}
              </button>
              <Show when={props.menu() === props.p.name}>
                <div
                  class="forest-popover absolute right-0 top-[calc(100%+6px)] z-30 w-[240px] cursor-default rounded-[9px] border border-solid border-del bg-[#18120f] px-3 py-[11px] text-left shadow-[0_10px_30px_-8px_rgba(0,0,0,0.6)]"
                  onClick={(e) => { e.preventDefault(); e.stopPropagation(); }}
                >
                  <p class="forest-popover-why m-0 mb-2 text-[11px] leading-[1.45] text-patina">
                    Rebase paused on a conflict{props.parked()?.current ? ` rebasing ${leaf(props.parked()!.current)}` : ""}. It holds a worktree and blocks restacks until it’s cleared.
                  </p>
                  <Show when={props.parked()?.reason}>{(r) => <p class="forest-popover-reason m-0 mb-2 text-[10.5px] leading-[1.4] text-del opacity-[0.85]">{r()}</p>}</Show>
                  <div class="forest-popover-actions flex flex-col gap-[6px]">
                    <button class={`${POP_BTN} border-patina text-patina hover:bg-[rgba(127,160,147,0.12)]`} onClick={(e) => { e.preventDefault(); e.stopPropagation(); props.resolve(props.p.name); }}>✦ resolve with Claude</button>
                    <button class={`danger ${POP_BTN} border-del text-del hover:bg-del-bg`} onClick={(e) => { e.preventDefault(); e.stopPropagation(); props.abort(props.p.name); }}>✕ abort & discard</button>
                  </div>
                </div>
              </Show>
            </div>
          </Match>
          <Match when={props.folded}>
            <Show when={props.p.merged && mergedAgo(props.p.merged.at)}>
              {(rel) => (
                <span class="forest-merged flex-none text-[11px] tracking-[0.03em] text-gold-leaf opacity-[0.85]" title={props.p.merged!.title}>
                  ✨ {(props.p.landed?.length ?? 0) > 1 ? `${props.p.landed!.length} landed · ${rel()}` : `${rel()} (#${props.p.merged!.pr})`}
                </span>
              )}
            </Show>
          </Match>
          {/* the shipping row's next step (nextStep, homeModel) — subsumes the PR badge and
              the behind trail (the dot still carries behind); ember when it's your move */}
          <Match when={props.next}>
            {(n) => (
              <span
                class={`forest-step font-mono text-[11px] whitespace-nowrap ${
                  n().start
                    ? "text-ember before:mr-2 before:rounded-[8px] before:border before:border-solid before:border-ember before:bg-ember-wash before:px-[6px] before:py-px before:text-[9px] before:uppercase before:tracking-[0.12em] before:content-['start']"
                    : !n().step.yourMove
                      ? "text-ink-faint"
                      : "text-ink-dim"
                }`}
                classList={{ start: n().start, wait: !n().step.yourMove }}
                title={n().step.title}
              >
                {n().step.text}
              </span>
            )}
          </Match>
          <Match when={props.p.behind > 0}>
            <span class="forest-trail opacity-0 transition-opacity duration-[120ms] group-hover:opacity-100">⟳ {props.p.behind} behind</span>
          </Match>
        </Switch>
      </span>
    </Link>
  );
}
