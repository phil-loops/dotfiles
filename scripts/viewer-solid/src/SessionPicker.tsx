import { createResource, createSignal, For, Show, onMount, onCleanup } from "solid-js";
import { Portal } from "solid-js/web";
import { claudeSessions } from "./chatDrawer";

// The ✦ buttons' destination picker (Phil, 2026-07-11): a seeded chat shouldn't always spawn a
// fresh pane — he keeps his Claude sessions parked in one tmux window and wants the seed drafted
// into one of THEM. The popover lists every live session (from /claude-sessions) plus the old
// "new pane" spawn as the first row. Render it inside a `relative inline-flex` wrapper
// (`.sp-anchor`, styled at each call site), gated by the caller's open signal; picking or
// clicking away closes it. onPick(undefined) = new pane; onPick(session_id) = draft into that
// session.
//
// The pop itself portals to <body> positioned fixed off the .sp-anchor rect — an in-place
// absolute pop gets clipped by overflow ancestors (FileRail's entry-head is overflow-hidden,
// the entry article overflow-clip) and out-stacked by later siblings' sticky headers.

const ITEM = "sp-item flex w-full cursor-pointer items-baseline gap-2 rounded-[5px] bg-transparent px-2 py-1.5 text-left leading-[1.55] text-ink hover:bg-[#221e1a]";
const EMPTY = "sp-empty px-2 pt-1 pb-1.5 text-[10.5px] italic text-[#6f675a]";
export function SessionPicker(props: { onPick: (session?: string) => void; onClose: () => void }) {
  const [sessions] = createResource(async () => (await claudeSessions()).sessions ?? []);
  const [pos, setPos] = createSignal<{ top: number; right: number } | null>(null);
  let marker: HTMLSpanElement | undefined;
  let el: HTMLDivElement | undefined;
  const away = (e: MouseEvent) => {
    if (el && !el.contains(e.target as Node)) {
      props.onClose();
    }
  };
  const key = (e: KeyboardEvent) => {
    if (e.key === "Escape") {
      e.stopPropagation();
      props.onClose();
    }
  };
  const drift = (e: Event) => {
    // fixed positioning doesn't track a scrolling anchor — close instead of floating away
    if (!el || !el.contains(e.target as Node)) {
      props.onClose();
    }
  };
  onMount(() => {
    const anchor = marker?.parentElement;
    if (anchor) {
      const r = anchor.getBoundingClientRect();
      setPos({ top: r.bottom + 6, right: Math.max(8, window.innerWidth - r.right) });
    }
    // capture phase, registered after the opening click's mousedown already fired — so the
    // very next press anywhere outside dismisses, even on stopPropagation-happy targets.
    document.addEventListener("mousedown", away, true);
    document.addEventListener("keydown", key, true);
    document.addEventListener("scroll", drift, true);
    window.addEventListener("resize", drift);
  });
  onCleanup(() => {
    document.removeEventListener("mousedown", away, true);
    document.removeEventListener("keydown", key, true);
    document.removeEventListener("scroll", drift, true);
    window.removeEventListener("resize", drift);
  });
  const idle = (s: number) => (s < 60 ? "now" : s < 3600 ? `${Math.round(s / 60)}m` : `${Math.round(s / 3600)}h`);
  return (
    <>
      <span ref={marker} class="hidden" aria-hidden="true" />
      <Show when={pos()}>
        {(p) => (
          <Portal>
            <div
              class="session-pop fixed z-[62] flex w-[260px] cursor-default flex-col gap-px rounded-lg border border-[#3a332b] bg-[#1b1815] p-[5px] text-left text-[11.5px] normal-case not-italic shadow-[0_12px_32px_rgba(0,0,0,.5)] [letter-spacing:normal]"
              style={{ top: `${p().top}px`, right: `${p().right}px` }}
              ref={el}
            >
              <div class="sp-head px-2 pt-1 pb-[5px] text-[9.5px] tracking-[.08em] uppercase text-[#6f675a]">seed into…</div>
              <button class={ITEM} onClick={() => props.onPick(undefined)}>
                <span class="sp-target flex-none text-patina">＋ new pane</span>
                <span class="sp-name overflow-hidden text-[10.5px] text-ellipsis whitespace-nowrap text-[#a89e8c]">split beside you</span>
              </button>
              <Show when={sessions()} fallback={<div class={EMPTY}>finding live sessions…</div>}>
                {(list) => (
                  <>
                    <For each={list()}>
                      {(s) => (
                        <button class={ITEM} onClick={() => props.onPick(s.session_id)}>
                          <span class="sp-target flex-none text-patina">{s.repo_name}</span>
                          <span class="sp-name overflow-hidden text-[10.5px] text-ellipsis whitespace-nowrap text-[#a89e8c]">{s.branch || s.area}</span>
                          <span class="sp-where ml-auto flex-none text-[10px] whitespace-nowrap text-[#6f675a]">{s.addr || s.pane} · {idle(s.idle_s)}</span>
                        </button>
                      )}
                    </For>
                    <Show when={!list().length}>
                      <div class={EMPTY}>no other live sessions — new pane it is</div>
                    </Show>
                  </>
                )}
              </Show>
            </div>
          </Portal>
        )}
      </Show>
    </>
  );
}
