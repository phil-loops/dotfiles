import { createMemo, Show, For } from "solid-js";
import { Link } from "./router";
import { ActionBar, type Action } from "./actions";
import { canMutate } from "./provider";
import { leaf, mergedAgo } from "./shared";
import type { PR, Project, ReviewRequest } from "./types";

// The Work tab: what needs you (changes requested) → what's in flight (open, by forest) →
// what just landed (merged < 1d). Fed the PR/review data plus the shared forestOf/landedRecently
// derivations (shared with NextQueue) and the review-import mutation.
export function WorkTab(props: {
  prs: () => PR[] | undefined;
  reviewReqs: () => ReviewRequest[] | undefined;
  tab: () => string;
  importReview: { isPending: boolean; variables?: number; mutate: (n: number) => void };
  forestOf: (name: string) => Project | undefined;
  landedRecently: (p: PR) => boolean;
}) {
  const workCount = () => (props.prs() || []).length + (props.reviewReqs() || []).length;
  const mergedOf = (p: PR) => {
    const m = props.forestOf(p.project)?.merged;
    return m && (m.pr === p.num || m.branch === p.branch) ? m : undefined;
  };
  type WorkState = "changes" | "review" | "pending" | "draft" | "landed";
  const prState = (p: PR): WorkState =>
    props.landedRecently(p) ? "landed"
    : p.review === "CHANGES_REQUESTED" ? "changes"
    : p.review === "APPROVED" ? "review"
    : p.draft ? "draft"
    : "pending";
  // Work tab partitions: what needs you (changes requested) → what's in flight (open, by
  // forest) → what just landed (merged < 1d, then it drops off on its own).
  const needsYouPRs = createMemo(() =>
    (props.prs() || []).filter((p) => !props.landedRecently(p) && p.review === "CHANGES_REQUESTED"));
  const inFlightByProject = createMemo<[string, PR[]][]>(() => {
    const m = new Map<string, PR[]>();
    for (const p of props.prs() || []) {
      if (props.landedRecently(p) || p.review === "CHANGES_REQUESTED") continue;
      const k = p.project || "—";
      (m.get(k) ?? m.set(k, []).get(k)!).push(p);
    }
    return [...m.entries()];
  });
  const landedPRs = createMemo(() => (props.prs() || []).filter((p) => props.landedRecently(p)));
  // one verdict per in-flight forest, replacing the 4-fact comma run in the old header.
  const forestVerdict = (proj: string, list: PR[]): { label: string; state: WorkState } => {
    const f = props.forestOf(proj);
    if (list.some((p) => p.review === "APPROVED")) return { label: "in review", state: "review" };
    if (f && f.behind > 60) return { label: `${f.behind} behind · stale`, state: "changes" };
    if (list.every((p) => p.draft)) return { label: "draft", state: "draft" };
    return { label: "open", state: "pending" };
  };
  // the trailing slot of a work row — a landed row reads "forest · ago ✓"; everything else keeps
  // the review mark (▲ changes / ✓ approved / • pending) and a draft tag when relevant.
  const workRowTrail = (p: PR) => {
    if (props.landedRecently(p)) {
      const m = mergedOf(p)!;
      return (
        <>
    <span class="work-meta">{p.project} · {mergedAgo(m.at)}</span>
          <span class="pr-rev ok">✓</span>
        </>
      );
    }
    const [mark, cls] = review(p.review);
    return (
      <>
{p.draft && <span class="pr-draft">draft</span>}
        <span class={`pr-rev ${cls}`}>{mark}</span>
      </>
    );
  };

  // one work row, state-rail on the left. Forest-backed PRs route in-app and carry recessive
  // hover actions; a bare PR is itself the GitHub link, so it needs no action bar.
  // A landed row's answer to "what now": the forest's first mergeable root still
  // without a PR — the natural next push after a merge contracts the stack.
  const nextUp = (p: PR): string | undefined =>
    p.project ? props.forestOf(p.project)?.candidates?.[0] : undefined;

  const workRow = (p: PR) => {
    const state = prState(p);
    const body = (
      <>
        <span class="pr-num">#{p.num}</span>
        <span class="pr-title">{p.title}</span>
        {workRowTrail(p)}
      </>
    );
    return p.project ? (
      <div class={`work-row work-state-${state}`}>
        <Link class="work-link" to={{ kind: "forest", name: p.project, node: p.branch }}>{body}</Link>
        <Show when={state !== "landed"}>
          <span class="work-acts"><ActionBar actions={workRowActions(p)} /></span>
        </Show>
        <Show when={state === "landed" && nextUp(p)}>
          {(n) => (
            <Link class="work-next" to={{ kind: "forest", name: p.project!, node: n() }}>
              next ▸ {leaf(n())}
            </Link>
          )}
        </Show>
      </div>
    ) : (
      <a class={`work-row work-state-${state}`} href={p.url} target="_blank">{body}</a>
    );
  };
  const review = (r?: string | null): [string, string] =>
    r === "APPROVED" ? ["✓", "ok"] : r === "CHANGES_REQUESTED" ? ["▲", "chg"] : ["•", "req"];
  const githubAction = (url: string, branch: string): Action => ({
    id: "gh:" + branch,
    title: "open on GitHub",
    label: () => "↗ GitHub",
    run: () => window.open(url, "_blank"),
  });
  // GitHub link only — the worktree reveal moved to the node ⋯ menu (telemetry trim:
  // ≤4 uses in 10d didn't earn a pill on every work row).
  const workRowActions = (p: PR): Action[] => [githubAction(p.url, p.branch)];
  return (
    <>
      <Show when={props.tab() === "work" && needsYouPRs().length}>
        <section class="work-sec">
          <h2 class="eyebrow">needs you <span class="eyebrow-ask">— blocked or waiting on your call</span></h2>
          <div class="work-rule" />
          <For each={needsYouPRs()}>{(p) => workRow(p)}</For>
        </section>
      </Show>

      <Show when={props.tab() === "work" && (props.reviewReqs() || []).length}>
        <section class="work-sec">
          <h2 class="eyebrow">review requests <span class="eyebrow-ask">— teammates waiting on your review</span></h2>
          <div class="work-rule" />
          <For each={props.reviewReqs()}>
            {(r) => {
              const importing = () => props.importReview.isPending && props.importReview.variables === r.number;
              const body = (
                <>
                  <span class="pr-num">#{r.number}</span>
                  <span class="pr-title">{r.title}</span>
                  <span class="work-meta">@{r.author}</span>
                </>
              );
              return (
                <div class="work-row work-state-review">
                  {r.imported ? (
                    <Link class="work-link" to={{ kind: "review", pr: r.number }}>{body}</Link>
                  ) : (
                    <a class="work-link" href={r.url} target="_blank">{body}</a>
                  )}
                  {/* import is the primary act here + "on viewer ✓" is at-a-glance status, so both
                      stay visible (not folded into the hover-recessive work-acts the PR rows use). */}
                  <Show
                    when={canMutate && !r.imported}
                    fallback={<Show when={r.imported}><span class="review-on">on viewer ✓</span></Show>}
                  >
                    <button class="watch-pin review-import" disabled={importing()} onClick={() => props.importReview.mutate(r.number)}>
                      {importing() ? "importing…" : "import"}
                    </button>
                  </Show>
                </div>
              );
            }}
          </For>
        </section>
      </Show>

      <Show when={props.tab() === "work" && inFlightByProject().length}>
        <section class="work-sec">
          <h2 class="eyebrow">in flight <span class="eyebrow-ask">— your open work, by forest</span></h2>
          <div class="work-rule" />
          <For each={inFlightByProject()}>
            {([proj, list]) => {
              const v = forestVerdict(proj, list);
              return (
                <>
                  <div class={`work-forest work-state-${v.state}`}>
                    <Link class="work-forest-name" to={{ kind: "forest", name: proj }}>{proj}</Link>
                    <span class="work-verdict">{v.label}</span>
                    <Show when={props.forestOf(proj)}>
                      {(f) => <span class="work-meta">{f().branches} {f().branches === 1 ? "node" : "nodes"}</span>}
                    </Show>
                  </div>
                  <For each={list}>{(p) => workRow(p)}</For>
                </>
              );
            }}
          </For>
        </section>
      </Show>

      <Show when={props.tab() === "work" && landedPRs().length}>
        <section class="work-sec">
          <h2 class="eyebrow">just landed <span class="eyebrow-ask">— merged in the last day, then it fades</span></h2>
          <div class="work-rule" />
          <For each={landedPRs()}>{(p) => workRow(p)}</For>
        </section>
      </Show>
      <Show when={props.tab() === "work" && !workCount()}>
        <p class="tab-empty">Nothing waiting on you — no open PRs or review requests.</p>
      </Show>
    </>
  );
}
