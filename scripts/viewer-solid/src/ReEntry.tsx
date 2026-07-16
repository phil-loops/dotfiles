import { createSignal, createMemo, createEffect, Show, For } from "solid-js";
import { Link, type ViewerLocation } from "./router";
import { nextStep } from "./homeModel";
import type { Project, PR } from "./types";

// ── re-entry header: "since you were last here" ────────────────────────────
// The come-back-tomorrow surface. The forest bands answer "how close to merge is everything";
// they can't answer "I've been away 18h — what moved, and where do I pick up." This does:
// a digest of what changed since your LAST VISIT (per-browser localStorage anchor) plus a single
// Resume pointer to the forest you touched most recently and its next action. Quiet when nothing
// is new — the anchor silently advances so it never goes stale, and only holds (persisting the
// digest across refreshes) while there's unacknowledged news.
const SEEN_KEY = "viewerLastSeen";

// Human age of the anchor for the eyebrow. Unlike shared.mergedAgo this never caps/returns null —
// the "since" label must always render, even after a week away.
function ago(ms: number): string {
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 90) return "just now";
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}

export function ReEntry(props: {
  projects: () => Project[] | undefined;
  prOf: (name: string) => PR | undefined;
  reviewCount: () => number;
}) {
  const stored = Number(localStorage.getItem(SEEN_KEY)) || 0;
  // First-ever visit (no anchor) starts from now — no months-of-history dump on the first run.
  const [since, setSince] = createSignal(stored || Date.now());

  const target = (p: Project): ViewerLocation => ({
    kind: "forest",
    name: p.name,
    repo: p.repo && p.repo !== "loops" ? p.repo : undefined,
  });

  // forests whose newest own commit lands after the anchor — "you (or a fold-in) touched these".
  const committed = createMemo(() =>
    (props.projects() || [])
      .filter((p) => (p.lastCommit ?? 0) * 1000 > since())
      .sort((a, b) => (b.lastCommit ?? 0) - (a.lastCommit ?? 0)));

  // squash-merges into main that landed after the anchor, newest first.
  const merges = createMemo(() =>
    (props.projects() || [])
      .flatMap((p) => (p.landed || [])
        .filter((m) => Date.parse(m.at) > since())
        .map((m) => ({ p, ...m })))
      .sort((a, b) => Date.parse(b.at) - Date.parse(a.at)));

  // where you left off: the forest with the most recent local commit, and its single next action.
  const resume = createMemo(() => {
    const p = (props.projects() || [])
      .filter((x) => x.lastCommit)
      .sort((a, b) => (b.lastCommit ?? 0) - (a.lastCommit ?? 0))[0];
    return p ? { p, step: nextStep(p, props.prOf(p.name)) } : null;
  });

  const hasNews = createMemo(() =>
    committed().length > 0 || merges().length > 0 || props.reviewCount() > 0);

  // The anchor only moves forward when there's nothing to acknowledge: once projects have loaded
  // and no news survives the filter, stamp "seen up to now" so the digest never accumulates stale
  // history. While news is present the anchor holds — the digest persists across refreshes until
  // "caught up" is pressed. (Gated on loaded data so an in-flight fetch never stamps prematurely.)
  createEffect(() => {
    if (props.projects() !== undefined && !hasNews()) {
      const now = Date.now();
      localStorage.setItem(SEEN_KEY, String(now));
      if (since() < now) setSince(now);
    }
  });

  const catchUp = () => {
    const now = Date.now();
    localStorage.setItem(SEEN_KEY, String(now));
    setSince(now);
  };

  const MORE = 6;
  const commitNames = createMemo(() => committed().map((p) => p.name));
  const LINE = "reentry-line font-mono text-[12.5px] text-ink";

  return (
    <Show when={hasNews()}>
      <section class="reentry mt-[14px] mb-[18px] rounded-[4px] border border-rule border-l-2 border-l-gold-deep bg-vellum-raise px-[14px] py-[12px]">
        <div class="reentry-head flex items-baseline justify-between">
          <h2 class="eyebrow mt-[34px] mb-[12px] text-[10px] font-medium tracking-[0.22em] uppercase text-ink-faint">since you were here <span class="reentry-when font-normal text-ink-faint">— {ago(since())}</span></h2>
          <button class="reentry-caught cursor-pointer rounded-[3px] border border-rule bg-transparent px-2 py-[2px] font-mono text-[11px] text-ink-dim hover:border-gold-deep hover:text-gold-leaf" onClick={catchUp} title="mark everything below as seen">
            caught up ✓
          </button>
        </div>

        <div class="reentry-lines mt-2 flex flex-col gap-[3px]">
          <Show when={committed().length}>
            <div class={LINE}>
              <span class="reentry-n mr-1 font-semibold text-gold-leaf">{committed().length}</span>
              {committed().length === 1 ? "forest" : "forests"} moved
              <span class="reentry-names text-ink-dim">
                · {commitNames().slice(0, MORE).join(", ")}
                <Show when={commitNames().length > MORE}> +{commitNames().length - MORE} more</Show>
              </span>
            </div>
          </Show>

          <For each={merges().slice(0, 4)}>
            {(m) => (
              <div class={`reentry-merged ${LINE}`}>
                <Link class="reentry-mlink text-patina no-underline hover:text-gold-leaf" to={target(m.p)}>PR #{m.pr} merged</Link>
                <span class="reentry-names text-ink-dim">· {m.p.name}</span>
              </div>
            )}
          </For>
          <Show when={merges().length > 4}>
            <div class="reentry-line reentry-dim font-mono text-[12.5px] text-ink-faint">+{merges().length - 4} more merged</div>
          </Show>

          <Show when={props.reviewCount()}>
            <div class={LINE}>
              <span class="reentry-n mr-1 font-semibold text-gold-leaf">{props.reviewCount()}</span>
              awaiting your review
            </div>
          </Show>
        </div>

        <Show when={resume()}>
          {(r) => (
            <Link class="reentry-resume group mt-[10px] flex flex-wrap items-baseline gap-[10px] border-t border-rule pt-[10px] no-underline" to={target(r().p)}>
              <span class="reentry-resume-tag font-mono text-[12px] text-gold-leaf">▸ resume</span>
              <span class="reentry-resume-name font-semibold text-ink group-hover:text-gold-leaf">{r().p.name}</span>
              <Show when={r().p.lastCommit}>
                <span class="reentry-dim font-mono text-[11px] text-ink-faint">touched {ago((r().p.lastCommit as number) * 1000)}</span>
              </Show>
              <Show when={r().step}>
                <span
                  class={`reentry-resume-next ml-auto rounded-[3px] border px-2 py-px font-mono text-[11.5px] ${r().step?.yourMove ? "border-ember bg-ember-wash text-ember" : "border-rule text-ink-dim"}`}
                  classList={{ yours: !!r().step?.yourMove }}
                >
                  next: {r().step!.text}
                </span>
              </Show>
            </Link>
          )}
        </Show>
      </section>
    </Show>
  );
}
