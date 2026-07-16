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
  const STATE: Record<WorkState, string> = {
    changes: "[--state:#e8794a] [--state-edge:var(--color-del)] [--state-glow:rgba(232,121,74,0.5)]",
    review: "[--state:#f2c258] [--state-edge:var(--color-gold-deep)] [--state-glow:rgba(242,194,88,0.45)]",
    pending: "[--state:#9ec6b6]",
    draft: "[--state:#9d8d6b]",
    landed: "[--state:#8fb0a2] opacity-80",
  };
  const SEC = "work-sec mb-[30px]";
  const ASK = "eyebrow-ask ml-2 font-display text-[14px] normal-case italic tracking-normal text-ink-dim";
  const HRULE = "work-rule mb-[6px] h-px bg-rule";
  const ROW =
    "work-row group relative flex items-center gap-[14px] rounded-[9px] py-[11px] pr-[14px] pl-[20px] text-ink no-underline transition-[background] duration-[120ms] hover:bg-vellum-raise before:absolute before:left-0 before:top-[7px] before:bottom-[7px] before:w-[4px] before:rounded-[2px] before:bg-(--state) before:shadow-[0_0_9px_-1px_var(--state-glow,transparent)] before:content-['']";
  const LINK = "work-link flex flex-1 min-w-0 items-center gap-[14px] text-inherit no-underline";
  const META = "work-meta flex-none text-[11px] text-ink-faint";
  const PR_NUM = "pr-num flex-none text-[12px] text-ink-dim";
  const PR_REV = "pr-rev w-[14px] flex-none text-center text-[13px]";
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
    <span class={META}>{p.project} · {mergedAgo(m.at)}</span>
          <span class={`${PR_REV} ok text-add`}>✓</span>
        </>
      );
    }
    const [mark, cls] = review(p.review);
    return (
      <>
{p.draft && <span class="pr-draft flex-none rounded-[5px] border border-solid border-rule px-[6px] py-px text-[10px] uppercase tracking-[0.06em] text-ink-faint">draft</span>}
        <span class={`${PR_REV} ${cls}`}>{mark}</span>
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
        <span class={PR_NUM}>#{p.num}</span>
        <span class={`pr-title flex-1 overflow-hidden text-ellipsis whitespace-nowrap ${state === "landed" ? "text-ink-dim" : ""}`}>{p.title}</span>
        {workRowTrail(p)}
      </>
    );
    return p.project ? (
      <div class={`work-state-${state} ${ROW} ${STATE[state]}`}>
        <Link class={LINK} to={{ kind: "forest", name: p.project, node: p.branch }}>{body}</Link>
        <Show when={state !== "landed"}>
          <span class="work-acts flex-none opacity-0 transition-opacity duration-[120ms] focus-within:opacity-100 group-hover:opacity-100"><ActionBar actions={workRowActions(p)} /></span>
        </Show>
        <Show when={state === "landed" && nextUp(p)}>
          {(n) => (
            <Link class="work-next flex-none rounded-[5px] border border-solid border-transparent px-[6px] py-px font-mono text-[11px] whitespace-nowrap text-gold-deep no-underline hover:border-rule hover:bg-vellum-raise" to={{ kind: "forest", name: p.project!, node: n() }}>
              next ▸ {leaf(n())}
            </Link>
          )}
        </Show>
      </div>
    ) : (
      <a class={`work-state-${state} ${ROW} ${STATE[state]}`} href={p.url} target="_blank">{body}</a>
    );
  };
  const review = (r?: string | null): [string, string] =>
    r === "APPROVED" ? ["✓", "ok text-add"] : r === "CHANGES_REQUESTED" ? ["▲", "chg text-del"] : ["•", "req text-ink-faint"];
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
        <section class={SEC}>
          <h2 class="eyebrow">needs you <span class={ASK}>— blocked or waiting on your call</span></h2>
          <div class={HRULE} />
          <For each={needsYouPRs()}>{(p) => workRow(p)}</For>
        </section>
      </Show>

      <Show when={props.tab() === "work" && (props.reviewReqs() || []).length}>
        <section class={SEC}>
          <h2 class="eyebrow">review requests <span class={ASK}>— teammates waiting on your review</span></h2>
          <div class={HRULE} />
          <For each={props.reviewReqs()}>
            {(r) => {
              const importing = () => props.importReview.isPending && props.importReview.variables === r.number;
              const body = (
                <>
                  <span class={PR_NUM}>#{r.number}</span>
                  <span class="pr-title flex-1 overflow-hidden text-ellipsis whitespace-nowrap">{r.title}</span>
                  <span class={META}>@{r.author}</span>
                </>
              );
              return (
                <div class={`work-state-review ${ROW} ${STATE.review}`}>
                  {r.imported ? (
                    <Link class={LINK} to={{ kind: "review", pr: r.number }}>{body}</Link>
                  ) : (
                    <a class={LINK} href={r.url} target="_blank">{body}</a>
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
        <section class={SEC}>
          <h2 class="eyebrow">in flight <span class={ASK}>— your open work, by forest</span></h2>
          <div class={HRULE} />
          <For each={inFlightByProject()}>
            {([proj, list]) => {
              const v = forestVerdict(proj, list);
              return (
                <>
                  <div class={`work-forest work-state-${v.state} mx-[2px] mt-4 mb-1 flex items-baseline gap-[10px] ${STATE[v.state]}`}>
                    <Link class="work-forest-name font-display italic text-[15px] text-ink no-underline hover:text-gold-leaf" to={{ kind: "forest", name: proj }}>{proj}</Link>
                    <span class="work-verdict rounded-[6px] border border-solid border-[color:var(--state-edge,var(--color-rule))] px-[7px] py-px text-[10px] tracking-[0.05em] text-(--state)">{v.label}</span>
                    <Show when={props.forestOf(proj)}>
                      {(f) => <span class={META}>{f().branches} {f().branches === 1 ? "node" : "nodes"}</span>}
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
        <section class={SEC}>
          <h2 class="eyebrow">just landed <span class={ASK}>— merged in the last day, then it fades</span></h2>
          <div class={HRULE} />
          <For each={landedPRs()}>{(p) => workRow(p)}</For>
        </section>
      </Show>
      <Show when={props.tab() === "work" && !workCount()}>
        <p class="tab-empty">Nothing waiting on you — no open PRs or review requests.</p>
      </Show>
    </>
  );
}
