// The picker, as Helix's: a title, a filter you type into, the matching places with their source
// line; ↑/↓ (or C-j/C-k, C-n/C-p) walk it, ↵ opens the place, esc closes.
import { createEffect, For, Show } from "solid-js";
import { nav } from "./nav";
import { bind, dispatch } from "./runner";

const KEYS: Record<string, string> = { ArrowDown: "picker.down", ArrowUp: "picker.up", Enter: "picker.open", Escape: "picker.close" };
const CTRL: Record<string, string> = { j: "picker.down", n: "picker.down", k: "picker.up", p: "picker.up" };

export default function Picker() {
  let input: HTMLInputElement | undefined;
  let list: HTMLOListElement | undefined;
  createEffect(() => {
    if (nav.picker()) queueMicrotask(() => input?.focus());
  });
  createEffect(() => {
    const i = nav.index();
    list?.children[i]?.scrollIntoView({ block: "nearest" });
  });
  return (
    <Show when={nav.picker()}>
      {(p) => (
        <div class="fixed inset-x-0 top-[12vh] z-30 mx-auto flex max-h-[70vh] w-[min(860px,calc(100vw-32px))] flex-col border border-gold-deep bg-vellum-raise shadow-[0_16px_48px_rgba(0,0,0,0.5)]" role="dialog">
          <div class="flex items-baseline gap-3 border-b border-rule px-3 py-2">
            <span class="shrink-0 text-[11px] text-ink-faint">{p().title}</span>
            <input
              ref={input}
              class="min-w-0 flex-1 bg-transparent text-[13px] text-ink outline-none"
              placeholder="filter"
              autocomplete="off"
              value={nav.filter()}
              onInput={(e) => nav.typed(e.currentTarget.value)}
              onKeyDown={(e) => {
                const id = e.ctrlKey ? CTRL[e.key] : KEYS[e.key];
                if (!id) return;
                e.preventDefault();
                e.stopPropagation();
                dispatch(id, "key", { event: e });
              }}
            />
            <span class="shrink-0 text-[11px] text-ink-faint">
              {nav.shown().length}/{p().items.length}
            </span>
          </div>
          <ol ref={list} class="m-0 min-h-0 flex-1 list-none overflow-y-auto p-0 py-1 font-mono text-[11.5px]">
            <For each={nav.shown()} fallback={<li class="px-3 py-1 text-ink-faint">nothing matches</li>}>
              {(it, i) => (
                <li>
                  <button class="flex w-full items-baseline gap-3 px-3 py-0.5 text-left" classList={{ "bg-gold-wash text-ink": i() === nav.index(), "text-ink-dim": i() !== nav.index() }} onClick={bind("picker.open", String(i()))}>
                    <span class="shrink-0 whitespace-pre">{it.label}</span>
                    <span class="min-w-0 truncate text-ink-faint">{it.text ?? "…"}</span>
                  </button>
                </li>
              )}
            </For>
          </ol>
        </div>
      )}
    </Show>
  );
}
