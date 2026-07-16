import { createMemo, Show, For } from "solid-js";
import { Link } from "./router";
import { leaf } from "./shared";
import type { PR, Project, ReviewRequest } from "./types";
import type { ViewerLocation } from "./router";

type NextAction = {
  id: string; tier: number; tone: string; icon: string; verb: string;
  target: string; why: string; title?: string;
  href?: string; to?: ViewerLocation;
};

// NEXT — one ranked queue of concrete next actions (merge/unblock/open-PR/contract/review/decide),
// so you hop in at the top instead of triaging buckets. Pure function of the PR/forest/review data.
export function NextQueue(props: {
  prs: () => PR[] | undefined;
  projects: () => Project[] | undefined;
  reviewReqs: () => ReviewRequest[] | undefined;
  tab: () => string;
  landedRecently: (p: PR) => boolean;
}) {
  const STALE_BEHIND = 60; // a forest this far behind is rot to decide on, not work to open
  // tone = the blessing-spine palette; --nq drives the left rail, icon and verb per row
  const TONE: Record<string, string> = {
    ship: "[--nq:#e0ad4e] [--nq-glow:rgba(224,173,78,0.5)]",
    block: "[--nq:#e8794a] [--nq-glow:rgba(232,121,74,0.5)]",
    open: "[--nq:#9ec6b6]",
    contract: "[--nq:#9d8d6b]",
    review: "[--nq:#c9b896]",
    decide: "[--nq:var(--color-ink-faint)]",
  };
  const ROW =
    "relative flex items-baseline gap-[10px] rounded-[9px] py-[8px] pr-[14px] pl-[20px] text-ink no-underline transition-[background] duration-[120ms] hover:bg-vellum-raise before:absolute before:left-0 before:top-[6px] before:bottom-[6px] before:w-[4px] before:rounded-[2px] before:bg-(--nq) before:shadow-[0_0_9px_-1px_var(--nq-glow,transparent)] before:content-['']";
  const nextActions = createMemo<NextAction[]>(() => {
    const out: NextAction[] = [];
    const prList = props.prs() || [];
    const projs = props.projects() || [];
    const blockedMerge = (s?: string) => s === "BLOCKED" || s === "DIRTY";
    const tag = (p: PR) => `#${p.num}${p.project ? " " + p.project : " " + leaf(p.branch)}`;
    for (const p of prList) {
      if (p.draft || props.landedRecently(p)) continue;
      if (p.review === "APPROVED" && p.ci === "passing" && !blockedMerge(p.mergeState)) {
        out.push({ id: "merge:" + p.num, tier: 0, tone: "ship", icon: "⬆", verb: "merge",
          target: tag(p), why: "approved · CI green", title: p.title, href: p.url });
      } else if (p.review === "APPROVED" && (p.ci === "failing" || blockedMerge(p.mergeState))) {
        out.push({ id: "unblock:" + p.num, tier: 1, tone: "block",
          icon: p.ci === "failing" ? "↻" : "⚠", verb: p.ci === "failing" ? "fix CI" : "unblock",
          target: tag(p), why: p.ci === "failing" ? "approved · CI failing" : "approved · merge blocked",
          title: p.title, href: p.url });
      }
    }
    const hasPR = new Set(prList.filter((p) => p.project).map((p) => p.project));
    for (const pr of projs) {
      const loc: ViewerLocation = { kind: "forest", name: pr.name, repo: pr.repo };
      if (pr.merged) {
        out.push({ id: "contract:" + pr.name, tier: 3, tone: "contract", icon: "✂",
          verb: "contract", target: pr.name, why: "merged · node lingering", to: loc });
      } else if (!pr.prOpened && !hasPR.has(pr.name) && pr.mergeable?.length && pr.behind < STALE_BEHIND) {
        out.push({ id: "open:" + pr.name, tier: 2, tone: "open", icon: "↗", verb: "open PR",
          target: pr.name, why: pr.behind > 0 ? `${pr.behind} behind · no PR yet` : "clean · no PR yet", to: loc });
      } else if (!pr.merged && pr.behind >= STALE_BEHIND) {
        out.push({ id: "decide:" + pr.name, tier: 5, tone: "decide", icon: "✦",
          verb: "decide", target: pr.name, why: `${pr.behind} behind · revive or drop`, to: loc });
      }
    }
    for (const r of props.reviewReqs() || []) {
      out.push({ id: "review:" + r.number, tier: 4, tone: "review", icon: "\u{1F441}",
        verb: "review", target: `#${r.number}`, why: `requested of you · @${r.author}`,
        title: r.title, href: r.url });
    }
    return out.sort((a, b) => a.tier - b.tier);
  });
  const nextRowBody = (a: NextAction) => (
    <>
      <span class="nq-icon w-[16px] flex-none text-center text-[13px] text-(--nq)">{a.icon}</span>
      <span class="nq-verb flex-none text-[13px] font-semibold tracking-[0.02em] text-(--nq)">{a.verb}</span>
      <span class="nq-target flex-none font-mono text-[12px] text-ink">{a.target}</span>
      <span class="nq-why min-w-0 flex-1 overflow-hidden text-ellipsis whitespace-nowrap text-[11px] text-ink-faint">{a.why}</span>
    </>
  );
  return (
      <Show when={props.tab() === "work" && nextActions().length}>
        <section class="work-sec next-queue mb-[30px]">
          <h2 class="eyebrow mt-[34px] mb-[12px] text-[10px] font-medium tracking-[0.22em] uppercase text-ink-faint">next <span class="eyebrow-ask ml-2 font-display text-[14px] normal-case italic tracking-normal text-ink-dim">— what to do, ranked</span></h2>
          <div class="work-rule mb-[6px] h-px bg-rule" />
          <For each={nextActions()}>
            {(a) =>
              a.to ? (
                <Link class={`nq-row nq-${a.tone} ${ROW} ${TONE[a.tone]}`} to={a.to} title={a.title}>
                  {nextRowBody(a)}
                </Link>
              ) : (
                <a class={`nq-row nq-${a.tone} ${ROW} ${TONE[a.tone]}`} href={a.href} target="_blank" rel="noopener" title={a.title}>
                  {nextRowBody(a)}
                </a>
              )
            }
          </For>
        </section>
      </Show>
  );
}
