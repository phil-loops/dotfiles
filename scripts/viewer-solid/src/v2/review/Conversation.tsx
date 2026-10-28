// The Conversation tab: the PR's body, then its timeline — reviews, top-level comments and the
// conversations on the diff — oldest first, the second reader's "nobody flagged" list, and the way
// to GitHub, where Phil submits his pending review.
import { createSelector, For, Match, Show, Switch } from "solid-js";
import Key from "../Key";
import { bind } from "../runner";
import { world } from "../store";
import { renderMarkdown } from "./markdown";
import { page as pg } from "./page";
import { ago, ThreadView } from "./Thread";

const STATE: Record<string, string> = {
  APPROVED: "approved these changes",
  CHANGES_REQUESTED: "requested changes",
  COMMENTED: "reviewed",
  DISMISSED: "had a review dismissed",
};

export default function Conversation() {
  const c = () => pg.conv();
  const selected = createSelector(() => pg.here()?.key);
  /** a card the cursor can rest on: j/k walk them, a click puts the cursor there */
  const card = (key: string) => ({
    "data-stop": key,
    get classList() {
      return { "rv-on": selected(key) };
    },
    onClick: bind("review.cursor.set", key),
  });
  return (
    <div class="rv-conv" data-paint={world.ready ? "review" : undefined}>
      <Show when={c()} fallback={<p class="rv-quiet">no PR</p>}>
        <article class="rv-card" {...card("c|body")}>
          <div class="rv-c-head">
            <span class="rv-author">{c()!.author}</span>
            <span class="text-ink-faint">opened #{c()!.number} · {c()!.headRef} → {c()!.base}</span>
          </div>
          <div class="md" innerHTML={renderMarkdown(c()!.body || "_No description._")} />
        </article>
        <For each={pg.timeline()}>
          {(it) => (
            <Switch>
              <Match when={it.kind === "review" && it}>
                {(x) => (
                  <article class="rv-card rv-card-review" {...card(pg.cardKey(it))}>
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
                  <article class="rv-card" {...card(pg.cardKey(it))}>
                    <div class="rv-c-head">
                      <span class="rv-author">{x().c.author}</span>
                      <span class="text-ink-faint">{ago(x().c.at)}</span>
                    </div>
                    <div class="md" innerHTML={renderMarkdown(x().c.body)} />
                  </article>
                )}
              </Match>
              <Match when={it.kind === "thread" && it}>
                {(x) => <ThreadView id={x().t.id} selected={selected} aside />}
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
          <Show when={c()!.pending?.count} fallback={<span class="text-ink-faint">no pending comments</span>}>
            {c()!.pending!.count} comment{c()!.pending!.count === 1 ? "" : "s"} in your pending review —
          </Show>
          <button class="rv-btn rv-btn-gold" onClick={bind("review.finish")}>
            submit on GitHub <kbd><Key id="review.finish" /></kbd>
          </button>
        </div>
      </Show>
    </div>
  );
}
