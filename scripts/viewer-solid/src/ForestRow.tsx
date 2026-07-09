import { Show, Switch, Match } from "solid-js";
import { Link } from "./router";
import { deleteMode } from "./deleteMode";
import { canMutate } from "./provider";
import { ActionBar, type Action } from "./actions";
import { leaf, mergedAgo } from "./shared";
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
}) {
  const stuck = () => props.parked()?.project === props.p.name;
  return (
    <Link
      class="forest-row"
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
      <span class={`forest-dot ${stuck() ? "parked" : props.p.behind > 0 ? "behind" : "fresh"}`} />
      <span class="forest-name">{props.p.name}</span>
      <Show when={props.hasLiveChat(props.p)}>
        <span class="forest-chat" title="a chat is running on this forest">✦</span>
      </Show>
      {/* ONE status cell, by precedence (Phil, strike 5: "a row = name + one signal") —
          drop-mode > parked repair > merged fold > behind count > open PR. Pips live on
          the tier header, node count on the overview; no signal at all = fresh. */}
      <span class="fcell trail">
        <Switch
          fallback={
            <Show when={props.prOf(props.p.name)}>
              {(pr) => (
                <span class="forest-pr" classList={{ draft: pr().draft }} title={pr().title}>
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
            <div class="forest-parked">
              <button
                class="forest-resolve"
                classList={{ open: props.menu() === props.p.name }}
                onClick={(e) => { e.preventDefault(); e.stopPropagation(); props.setMenu(props.menu() === props.p.name ? null : props.p.name); }}
              >
                ⚠ parked at {leaf(props.parked()?.current || props.p.name)}
              </button>
              <Show when={props.menu() === props.p.name}>
                <div class="forest-popover" onClick={(e) => { e.preventDefault(); e.stopPropagation(); }}>
                  <p class="forest-popover-why">
                    Rebase paused on a conflict{props.parked()?.current ? ` rebasing ${leaf(props.parked()!.current)}` : ""}. It holds a worktree and blocks restacks until it’s cleared.
                  </p>
                  <Show when={props.parked()?.reason}>{(r) => <p class="forest-popover-reason">{r()}</p>}</Show>
                  <div class="forest-popover-actions">
                    <button onClick={(e) => { e.preventDefault(); e.stopPropagation(); props.resolve(props.p.name); }}>✦ resolve with Claude</button>
                    <button class="danger" onClick={(e) => { e.preventDefault(); e.stopPropagation(); props.abort(props.p.name); }}>✕ abort & discard</button>
                  </div>
                </div>
              </Show>
            </div>
          </Match>
          <Match when={props.folded}>
            <Show when={props.p.merged && mergedAgo(props.p.merged.at)}>
              {(rel) => (
                <span class="forest-merged" title={props.p.merged!.title}>
                  ✨ {(props.p.landed?.length ?? 0) > 1 ? `${props.p.landed!.length} landed · ${rel()}` : `${rel()} (#${props.p.merged!.pr})`}
                </span>
              )}
            </Show>
          </Match>
          <Match when={props.p.behind > 0}>
            <span class="forest-trail">⟳ {props.p.behind} behind</span>
          </Match>
        </Switch>
      </span>
    </Link>
  );
}
