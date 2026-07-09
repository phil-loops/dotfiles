import { Show } from "solid-js";
import { Link, forestRepo, type ViewerLocation } from "./router";
import { leaf, interestPips } from "./shared";
import { canMutate } from "./provider";
import { chatToTmux } from "./chatDrawer";
import { DivergedDetailPanel, type DivergedDetail } from "./DivergedDetailPanel";
import { NodeActions } from "./NodeActions";
import type { NodeData, FileDiff } from "./types";

type HealthEntry = {
  drifted?: boolean; merged?: boolean; parent?: string;
  upstream?: string; upstreamBad?: boolean; upstreamReason?: string;
  diverged?: boolean; ahead?: number; behind?: number;
};

// The node review header: forest strip (back to the map) + branch identity/health + the tier-2
// action bar (NodeActions + whole-branch chat). A wide prop surface because it mirrors the review
// surface's state and fires its mutations.
export function NodeHeader(props: {
  location: () => ViewerLocation;
  project: () => string;
  isGhost: () => boolean;
  active: () => string;
  parentOf: () => string | undefined;
  interestOf: () => number;
  reseatChildren: { isPending: boolean; data?: { ok: boolean; conflicts: { branch: string; err: string }[] } | null; mutate: (p: string) => void };
  detachUpstream: { isPending: boolean; mutate: (b: string) => void };
  bumpInterest: { mutate: (arg: { project: string; delta: number }) => void };
  divergedOpen: () => boolean;
  setDivergedOpen: (v: boolean) => void;
  nodeHealth: (b: string) => HealthEntry | undefined;
  divergedData: () => DivergedDetail | undefined;
  view: () => "diffs" | "commits";
  base: () => string;
  BASES: [string, string][];
  nodeAmbient: (b: string) => { verdict?: string; behind?: number | null; conflict_pr?: number | null; conflict_title?: string | null } | undefined;
  nodeData: () => NodeData | undefined;
  blessedOf: (f: FileDiff) => boolean;
  setShowChats: (v: boolean) => void;
}) {
  return (
        <header class="node-head">
          {/* forest strip — forest altitude: which project + restack-forest. Lifted out of the
              branch control bar so forest-scope actions stop bleeding into branch controls. */}
          <div
            class="nh-forest"
            style={{
              display: "flex",
              "align-items": "center",
              gap: "10px",
              "padding-bottom": "10px",
              "border-bottom": "1px solid var(--rule)",
            }}
          >
            <Show
              when={props.location().kind === "forest"}
              fallback={
                <span
                  style={{
                    "font-size": "11px",
                    "letter-spacing": "0.07em",
                    "text-transform": "uppercase",
                    color: "var(--ink-faint)",
                  }}
                >
                  {props.project()}
                </span>
              }
            >
              <Link
                class="nh-forest-back"
                to={{ kind: "forest", name: props.project(), repo: forestRepo(props.location()) }}
                title="back to the forest map — your current node stays highlighted there"
              >
                ⊞ {props.project()}
              </Link>
            </Show>
            <div class="nh-spacer" />
          </div>
          {/* branch strip — identity: the branch name + what it's diffed against + health badges. */}
          <div class="nh-id">
            <h1>{props.isGhost() ? `✦ ${props.project()}` : leaf(props.active()) || "—"}</h1>
            <Show
              when={props.isGhost()}
              fallback={
                <Show when={props.parentOf()}>
                  <span class="against">◂ {leaf(props.parentOf())}</span>
                </Show>
              }
            >
              <span class="against">◂ main · all changes on this project</span>
            </Show>
            <Show when={!props.isGhost() && props.interestOf() > 0}>
              <span class="nh-ready" title={`interest ${props.interestOf()} — this forest is promoted on the Forests home`}>
                {interestPips(props.interestOf())}
              </span>
            </Show>
            {/* health badges folded into the spine (reasons tooltip + ⋯ overrides) — what
                remains here is only the transient outcome of a repair fired from ⋯. */}
            <Show when={props.reseatChildren.isPending || props.detachUpstream.isPending}>
              <span class="nh-drift">{props.reseatChildren.isPending ? "⤴ reseating…" : "✂ detaching…"}</span>
            </Show>
            <Show when={props.reseatChildren.data && !props.reseatChildren.data.ok}>
              <span
                class="nh-drift"
                title={props.reseatChildren.data!.conflicts.map((c) => `${c.branch}: ${c.err}`).join("\n")}
              >
                ⚠ reseat: {props.reseatChildren.data!.conflicts.length} conflicted — resolve by hand or restack
              </span>
            </Show>
          </div>
          <Show when={props.divergedOpen() && props.nodeHealth(props.active())?.diverged}>
            <DivergedDetailPanel data={props.divergedData()} />
          </Show>
          {/* tier 2 — controls: view switches on the left, branch state + actions on the right.
              The blessed count lives in the spine; the map opens from the spine + `m`. */}
          {/* tier-2 (Phil, strikes 6+7): no view controls at all — c flips diffs⇄commits,
              1/2/3 set the diff base, both taught in ? help. The base shows as passive text
              only when it's not the default, so a non-parent diff can't masquerade. */}
          <div class="nh-bar">
            <Show when={props.view() === "commits"}>
              <span class="nh-viewnote">commits · c for diffs</span>
            </Show>
            <Show when={props.view() === "diffs" && props.base() !== "" && !props.isGhost()}>
              <span class="nh-viewnote">vs {(props.BASES.find(([v]) => v === props.base()) ?? props.BASES[0])[1]} · 1 for parent</span>
            </Show>
            <div class="nh-spacer" />
            <Show when={!props.isGhost()}>
              <NodeActions
                branch={props.active()}
                isReview={props.location().kind === "review"}
                merged={props.nodeHealth(props.active())?.merged}
                ambient={props.nodeAmbient(props.active())}
                blessing={props.nodeData() ? { total: props.nodeData()!.files.length, blessed: props.nodeData()!.files.filter(props.blessedOf).length } : undefined}
                health={props.nodeHealth(props.active())}
                onReseat={() => { const p = props.nodeHealth(props.active())?.parent; if (p) props.reseatChildren.mutate(p); }}
                onDetach={() => props.detachUpstream.mutate(props.active())}
                onInspect={() => props.setDivergedOpen(!props.divergedOpen())}
                interest={canMutate ? props.interestOf() : undefined}
                onBump={canMutate ? (delta) => props.bumpInterest.mutate({ project: props.project(), delta }) : undefined}
                onAllChats={() => props.setShowChats(true)}
              />
            </Show>
            <Show when={canMutate}>
              <button class="icon-btn" onClick={() => chatToTmux({ branch: props.active() })} title="chat about this whole branch — opens an interactive claude beside your tmux panes">
                ✦
              </button>
            </Show>
          </div>
        </header>
  );
}
