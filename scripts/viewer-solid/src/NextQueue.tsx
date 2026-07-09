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
      <span class="nq-icon">{a.icon}</span>
      <span class="nq-verb">{a.verb}</span>
      <span class="nq-target">{a.target}</span>
      <span class="nq-why">{a.why}</span>
    </>
  );
  return (
      <Show when={props.tab() === "work" && nextActions().length}>
        <section class="work-sec next-queue">
          <h2 class="eyebrow">next <span class="eyebrow-ask">— what to do, ranked</span></h2>
          <div class="work-rule" />
          <For each={nextActions()}>
            {(a) =>
              a.to ? (
                <Link class={`nq-row nq-${a.tone}`} to={a.to} title={a.title}>
                  {nextRowBody(a)}
                </Link>
              ) : (
                <a class={`nq-row nq-${a.tone}`} href={a.href} target="_blank" rel="noopener" title={a.title}>
                  {nextRowBody(a)}
                </a>
              )
            }
          </For>
        </section>
      </Show>
  );
}
