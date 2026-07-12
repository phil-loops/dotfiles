import { createResource, For, Show, onMount, onCleanup } from "solid-js";
import { claudeSessions } from "./chatDrawer";

// The ✦ buttons' destination picker (Phil, 2026-07-11): a seeded chat shouldn't always spawn a
// fresh pane — he keeps his Claude sessions parked in one tmux window and wants the seed drafted
// into one of THEM. The popover lists every live session (from /claude-sessions) plus the old
// "new pane" spawn as the first row. Render it inside a `position: relative` wrapper
// (`.sp-anchor`), gated by the caller's open signal; picking or clicking away closes it.
// onPick(undefined) = new pane; onPick(session_id) = draft into that session.
export function SessionPicker(props: { onPick: (session?: string) => void; onClose: () => void }) {
  const [sessions] = createResource(async () => (await claudeSessions()).sessions ?? []);
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
  onMount(() => {
    // capture phase, registered after the opening click's mousedown already fired — so the
    // very next press anywhere outside dismisses, even on stopPropagation-happy targets.
    document.addEventListener("mousedown", away, true);
    document.addEventListener("keydown", key, true);
  });
  onCleanup(() => {
    document.removeEventListener("mousedown", away, true);
    document.removeEventListener("keydown", key, true);
  });
  const idle = (s: number) => (s < 60 ? "now" : s < 3600 ? `${Math.round(s / 60)}m` : `${Math.round(s / 3600)}h`);
  return (
    <div class="session-pop" ref={el}>
      <div class="sp-head">seed into…</div>
      <button class="sp-item" onClick={() => props.onPick(undefined)}>
        <span class="sp-target">＋ new pane</span>
        <span class="sp-name">split beside you</span>
      </button>
      <Show when={sessions()} fallback={<div class="sp-empty">finding live sessions…</div>}>
        {(list) => (
          <>
            <For each={list()}>
              {(s) => (
                <button class="sp-item" onClick={() => props.onPick(s.session_id)}>
                  <span class="sp-target">{s.repo_name}</span>
                  <span class="sp-name">{s.branch || s.area}</span>
                  <span class="sp-where">{s.addr || s.pane} · {idle(s.idle_s)}</span>
                </button>
              )}
            </For>
            <Show when={!list().length}>
              <div class="sp-empty">no other live sessions — new pane it is</div>
            </Show>
          </>
        )}
      </Show>
      <style>{SP_CSS}</style>
    </div>
  );
}

const SP_CSS = `
.sp-anchor { position: relative; display: inline-flex; }
.session-pop {
  position: absolute; top: calc(100% + 6px); right: 0; z-index: 62; width: 260px;
  padding: 5px; border-radius: 8px; border: 1px solid var(--line, #3a332b);
  background: var(--raised, #1b1815); box-shadow: 0 12px 32px rgba(0,0,0,.5);
  display: flex; flex-direction: column; gap: 1px; cursor: default; text-align: left;
  font-size: 11.5px; font-style: normal; letter-spacing: normal; text-transform: none;
}
.sp-head { font-size: 9.5px; letter-spacing: .08em; text-transform: uppercase; color: var(--faint, #6f675a); padding: 4px 8px 5px; }
.sp-item {
  display: flex; align-items: baseline; gap: 8px; width: 100%;
  font: inherit; text-align: left; cursor: pointer;
  color: var(--ink, #e9e2d4); background: transparent; border: 0; border-radius: 5px; padding: 6px 8px;
}
.sp-item:hover { background: var(--panel, #221e1a); }
.sp-target { color: var(--patina, #8a9a6b); flex: none; }
.sp-name { color: var(--dim, #a89e8c); font-size: 10.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.sp-where { margin-left: auto; flex: none; color: var(--faint, #6f675a); font-size: 10px; white-space: nowrap; }
.sp-empty { font-size: 10.5px; color: var(--faint, #6f675a); padding: 4px 8px 6px; font-style: italic; }
`;
