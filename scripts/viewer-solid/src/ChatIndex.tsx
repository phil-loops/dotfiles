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

const CI_STATE = "ci-state mr-[7px] text-[10px] uppercase tracking-[0.04em]";

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
    <div class="chat-index-backdrop fixed inset-0 z-[210] flex justify-end bg-[rgba(8,6,3,0.78)] backdrop-blur-[2px]" onClick={props.onClose}>
      <aside
        class="chat-index h-full w-[380px] max-w-[92vw] overflow-y-auto border-l border-rule bg-[linear-gradient(180deg,var(--color-vellum-raise),var(--color-vellum-night))] shadow-[-18px_0_40px_rgba(0,0,0,0.4)]"
        onClick={(e) => e.stopPropagation()}
      >
        <header class="ci-head sticky top-0 z-[1] flex items-center justify-between border-b border-rule bg-vellum-raise px-4 py-[14px]">
          <span class="ci-title text-[14px] text-ink">💬 chats</span>
          <button class="icon-btn" onClick={props.onClose} title="close">
            ×
          </button>
        </header>
        <Show
          when={chatSummaries().length}
          fallback={<p class="ci-empty px-4 py-[22px] italic text-ink-faint">no chats yet — open ✦ chat on any file</p>}
        >
          <div class="ci-list pt-2 pb-8">
            <For each={groups()}>
              {([branch, rows]) => (
                <section class="ci-group py-[6px]">
                  <h4
                    class="ci-branch m-0 cursor-pointer px-4 pt-2 pb-1 text-[11px] uppercase tracking-[0.06em] text-gold-leaf hover:text-ink"
                    onClick={() => open(branch)}
                    title={branch}
                  >
                    {leaf(branch)}
                  </h4>
                  <For each={rows}>
                    {(r) => (
                      <button
                        class="ci-row flex w-full cursor-pointer flex-col gap-[3px] border-0 border-l-2 border-transparent bg-transparent px-4 py-[7px] text-left hover:border-l-gold-leaf hover:bg-vellum-edge"
                        onClick={() => props.onOpen(branch, r.path)}
                      >
                        <span class="ci-row-top flex items-baseline justify-between gap-[10px]">
                          <span class="ci-file overflow-hidden text-ellipsis whitespace-nowrap text-[13px] text-ink">{fileLeaf(r.path)}</span>
                          <span class="ci-meta flex-none text-[11px] text-ink-faint">
                            <Show when={r.working}>
                              <span class={`${CI_STATE} working text-ink-dim animate-chat-pulse motion-reduce:animate-none`}>working…</span>
                            </Show>
                            <Show when={!r.working && r.unseenDone}>
                              <span class={`${CI_STATE} done text-add`}>done ✓</span>
                            </Show>
                            {r.count} msg{r.count === 1 ? "" : "s"}
                            <Show when={r.writtenAt}> · {ago(r.writtenAt)}</Show>
                          </span>
                        </span>
                        <Show when={r.last}>
                          <span class="ci-snippet overflow-hidden text-ellipsis whitespace-nowrap text-[11px] leading-[1.4] text-ink-dim">
                            <span class="ci-who text-ink-faint">{r.last!.role === "you" ? "you" : "claude"}:</span>{" "}
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
