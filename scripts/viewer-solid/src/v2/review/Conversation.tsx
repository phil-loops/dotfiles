// The Conversation tab: the PR's body, then its timeline — reviews, top-level comments and the
// conversations on the diff — oldest first, the second reader's "nobody flagged" list, and the way
// to GitHub, where Phil submits his pending review.
import { createMemo, For, Match, Show, Switch } from "solid-js";
import { bind } from "../runner";
import { world } from "../store";
import type { Comment, Review, Thread } from "../types";
import { renderMarkdown, plain } from "./markdown";
import { page as pg } from "./page";
import { ago } from "./Thread";

type Item = { at: string; kind: "review"; r: Review } | { at: string; kind: "comment"; c: Comment } | { at: string; kind: "thread"; t: Thread };

const STATE: Record<string, string> = {
  APPROVED: "approved these changes",
  CHANGES_REQUESTED: "requested changes",
  COMMENTED: "reviewed",
  DISMISSED: "had a review dismissed",
};

export default function Conversation() {
  const c = () => pg.conv();
  const items = createMemo<Item[]>(() => {
    const cv = c();
    if (!cv) return [];
    const out: Item[] = [
      ...cv.reviews.filter((r) => r.body || r.state !== "COMMENTED").map((r) => ({ at: r.at, kind: "review" as const, r })),
      ...cv.comments.map((x) => ({ at: x.at, kind: "comment" as const, c: x })),
      ...pg.threads().map((t) => ({ at: t.comments[0]?.at ?? "", kind: "thread" as const, t })),
    ];
    return out.sort((a, b) => (a.at || "~").localeCompare(b.at || "~"));
  });
  return (
    <div class="rv-conv" data-paint={world.ready ? "review" : undefined}>
      <Show when={c()} fallback={<p class="rv-quiet">this branch has no open PR on GitHub — nothing to converse about yet</p>}>
        <article class="rv-card">
          <div class="rv-c-head">
            <span class="rv-author">{c()!.author}</span>
            <span class="text-ink-faint">opened #{c()!.number} · {c()!.headRef} → {c()!.base}</span>
          </div>
          <div class="md" innerHTML={renderMarkdown(c()!.body || "_No description._")} />
        </article>
        <For each={items()}>
          {(it) => (
            <Switch>
              <Match when={it.kind === "review" && it}>
                {(x) => (
                  <article class="rv-card rv-card-review">
                    <div class="rv-c-head">
                      <span class="rv-author">{x().r.author}</span>
                      <span class={x().r.state === "APPROVED" ? "text-patina" : x().r.state === "CHANGES_REQUESTED" ? "text-ember" : "text-ink-dim"}>
                        {STATE[x().r.state] ?? x().r.state.toLowerCase()}
                      </span>
                      <span class="text-ink-faint">{ago(x().r.at)}</span>
                    </div>
                    <Show when={x().r.body}>
                      <div class="md" innerHTML={renderMarkdown(x().r.body)} />
                    </Show>
                  </article>
                )}
              </Match>
              <Match when={it.kind === "comment" && it}>
                {(x) => (
                  <article class="rv-card">
                    <div class="rv-c-head">
                      <span class="rv-author">{x().c.author}</span>
                      <span class="text-ink-faint">{ago(x().c.at)}</span>
                    </div>
                    <div class="md" innerHTML={renderMarkdown(x().c.body)} />
                  </article>
                )}
              </Match>
              <Match when={it.kind === "thread" && it}>
                {(x) => (
                  <button class="rv-tl-thread" classList={{ "rv-thread-done": x().t.resolved || x().t.outdated }} onClick={bind("review.thread.show", x().t.id)}>
                    <span class="rv-author">{x().t.comments[0]?.author}</span>
                    <span class="rv-where">
                      {x().t.path}:{x().t.local?.line ?? x().t.originalLine}
                    </span>
                    <span class="rv-summary">{plain(x().t.comments[0]?.body ?? "", 100)}</span>
                    <Show when={x().t.resolved}>
                      <span class="rv-chip rv-chip-ok">resolved</span>
                    </Show>
                    <Show when={x().t.outdated}>
                      <span class="rv-chip">outdated</span>
                    </Show>
                    <Show when={x().t.comments.length > 1}>
                      <span class="rv-chip">{x().t.comments.length - 1} more</span>
                    </Show>
                  </button>
                )}
              </Match>
            </Switch>
          )}
        </For>
        <Show when={c()!.unflagged?.items.length}>
          <article class="rv-card rv-note">
            <div class="rv-c-head">
              <span class="rv-note-mark">second reader</span>
              <span class="text-ink-faint">what no one flagged</span>
            </div>
            <For each={c()!.unflagged!.items}>
              {(u) => (
                <div class="rv-unflagged">
                  <code>{u.path}:{u.line}</code> — {u.why}
                </div>
              )}
            </For>
          </article>
        </Show>
        <div class="rv-pending-bar">
          <Show when={c()!.pending?.count} fallback={<span class="text-ink-faint">comment on a line in Files changed — it goes into your pending review, which you submit on GitHub</span>}>
            {c()!.pending!.count} comment{c()!.pending!.count === 1 ? "" : "s"} in your pending review —
          </Show>
          <button class="rv-btn rv-btn-gold" onClick={bind("review.finish")}>
            Open on GitHub to submit <kbd>S</kbd>
          </button>
        </div>
      </Show>
    </div>
  );
}
