import { For, Show } from "solid-js";
import { chatSummaries, type ChatSummary } from "./chatStore";
import { useViewerLocation } from "./router";

// Cross-forest index of every chat thread. Chats are stored per branch+file but only surfaced
// from that one file's ✦ drawer — so a conversation is invisible unless you remember where you
// had it. This panel makes them all visible at once: grouped by branch, newest first, click a
// row to jump to that branch's node (where the file's 💬 badge + ✦ chat reopen it). Read-only
// over the store; localStorage-scoped, so it's every chat in THIS browser.

const leaf = (b: string): string => b.split("/").pop() || b;
const fileLeaf = (p: string): string => (p ? p.split("/").pop() || p : "whole branch");

function ago(ms: number): string {
  if (!ms) return "";
  const s = Math.floor((Date.now() - ms) / 1000);
  if (s < 60) return "just now";
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}

export default function ChatIndex(props: {
  onClose: () => void;
  // open a chat in its branch+file context (navigate there + reopen the drawer). "" path → whole branch.
  onOpen: (branch: string, path: string) => void;
}) {
  const { navigate } = useViewerLocation();
  const groups = (): [string, ChatSummary[]][] => {
    const out: Record<string, ChatSummary[]> = {};
    for (const s of chatSummaries()) {
      (out[s.branch] ??= []).push(s);
    }
    return Object.entries(out);
  };
  // branch header → just jump to the branch (no specific chat). A row → reopen that exact chat.
  const open = (branch: string) => {
    navigate({ kind: "forest", name: branch });
    props.onClose();
  };
  return (
    <div class="chat-index-backdrop" onClick={props.onClose}>
      <aside class="chat-index" onClick={(e) => e.stopPropagation()}>
        <header class="ci-head">
          <span class="ci-title">💬 chats</span>
          <button class="icon-btn" onClick={props.onClose} title="close">
            ×
          </button>
        </header>
        <Show
          when={chatSummaries().length}
          fallback={<p class="ci-empty">no chats yet — open ✦ chat on any file</p>}
        >
          <div class="ci-list">
            <For each={groups()}>
              {([branch, rows]) => (
                <section class="ci-group">
                  <h4 class="ci-branch" onClick={() => open(branch)} title={branch}>
                    {leaf(branch)}
                  </h4>
                  <For each={rows}>
                    {(r) => (
                      <button class="ci-row" onClick={() => props.onOpen(branch, r.path)}>
                        <span class="ci-row-top">
                          <span class="ci-file">{fileLeaf(r.path)}</span>
                          <span class="ci-meta">
                            <Show when={r.working}>
                              <span class="ci-state working">working…</span>
                            </Show>
                            <Show when={!r.working && r.unseenDone}>
                              <span class="ci-state done">done ✓</span>
                            </Show>
                            {r.count} msg{r.count === 1 ? "" : "s"}
                            <Show when={r.writtenAt}> · {ago(r.writtenAt)}</Show>
                          </span>
                        </span>
                        <Show when={r.last}>
                          <span class="ci-snippet">
                            <span class="ci-who">{r.last!.role === "you" ? "you" : "claude"}:</span>{" "}
                            {r.last!.text.slice(0, 90)}
                          </span>
                        </Show>
                      </button>
                    )}
                  </For>
                </section>
              )}
            </For>
          </div>
        </Show>
      </aside>
    </div>
  );
}
