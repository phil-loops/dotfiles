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

  return (
    <Show when={hasNews()}>
      <section class="reentry">
        <div class="reentry-head">
          <h2 class="eyebrow mt-[34px] mb-[12px] text-[10px] font-medium tracking-[0.22em] uppercase text-ink-faint">since you were here <span class="reentry-when">— {ago(since())}</span></h2>
          <button class="reentry-caught" onClick={catchUp} title="mark everything below as seen">
            caught up ✓
          </button>
        </div>

        <div class="reentry-lines">
          <Show when={committed().length}>
            <div class="reentry-line">
              <span class="reentry-n">{committed().length}</span>
              {committed().length === 1 ? "forest" : "forests"} moved
              <span class="reentry-names">
                · {commitNames().slice(0, MORE).join(", ")}
                <Show when={commitNames().length > MORE}> +{commitNames().length - MORE} more</Show>
              </span>
            </div>
          </Show>

          <For each={merges().slice(0, 4)}>
            {(m) => (
              <div class="reentry-line reentry-merged">
                <Link class="reentry-mlink" to={target(m.p)}>PR #{m.pr} merged</Link>
                <span class="reentry-names">· {m.p.name}</span>
              </div>
            )}
          </For>
          <Show when={merges().length > 4}>
            <div class="reentry-line reentry-dim">+{merges().length - 4} more merged</div>
          </Show>

          <Show when={props.reviewCount()}>
            <div class="reentry-line">
              <span class="reentry-n">{props.reviewCount()}</span>
              awaiting your review
            </div>
          </Show>
        </div>

        <Show when={resume()}>
          {(r) => (
            <Link class="reentry-resume" to={target(r().p)}>
              <span class="reentry-resume-tag">▸ resume</span>
              <span class="reentry-resume-name">{r().p.name}</span>
              <Show when={r().p.lastCommit}>
                <span class="reentry-dim">touched {ago((r().p.lastCommit as number) * 1000)}</span>
              </Show>
              <Show when={r().step}>
                <span class="reentry-resume-next" classList={{ yours: !!r().step?.yourMove }}>
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
