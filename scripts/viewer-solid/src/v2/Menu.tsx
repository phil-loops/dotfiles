// `space`: every command in reach, filterable. Enter runs the highlighted one.
import { createMemo, createSignal, For, onMount, Show } from "solid-js";
import { model } from "./model";
import { commands } from "./registry";
import { bind, dispatch } from "./runner";
import { menuOpen, setMenuOpen } from "./ui";

export default function Menu() {
  return (
    <Show when={menuOpen()}>
      <MenuBody />
    </Show>
  );
}

function MenuBody() {
  const [q, setQ] = createSignal("");
  const [i, setI] = createSignal(0);
  let input!: HTMLInputElement;
  onMount(() => input.focus());
  const items = createMemo(() => {
    const scopes = model.selected() ? ["project", "global"] : ["global"];
    const needle = q().toLowerCase();
    return commands().filter((c) => !c.quiet && scopes.includes(c.scope) && (c.title + " " + c.id).toLowerCase().includes(needle));
  });
  const via = () => (q() ? "palette" : "menu");
  const run = (id: string, e: Event) => dispatch(id, via(), { event: e });
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "Escape") {
      e.preventDefault();
      setMenuOpen(false);
    } else if (e.key === "ArrowDown" || (e.ctrlKey && e.key === "n")) {
      e.preventDefault();
      setI((n) => Math.min(items().length - 1, n + 1));
    } else if (e.key === "ArrowUp" || (e.ctrlKey && e.key === "p")) {
      e.preventDefault();
      setI((n) => Math.max(0, n - 1));
    } else if (e.key === "Enter") {
      e.preventDefault();
      const c = items()[i()];
      if (c) run(c.id, e);
    }
  };
  return (
    <div class="fixed inset-0 z-20 flex items-start justify-center pt-[14vh]">
      <div class="absolute inset-0 bg-vellum-night/70" onClick={bind("overlay.close")} />
      <div class="relative w-[min(520px,92vw)] border border-rule bg-vellum-raise shadow-2xl">
        <input
          ref={input}
          value={q()}
          onInput={(e) => {
            setQ(e.currentTarget.value);
            setI(0);
          }}
          onKeyDown={onKey}
          placeholder="run a command…"
          class="w-full border-0 border-b border-rule bg-transparent px-4 py-3 outline-none placeholder:text-ink-faint"
        />
        <ul class="m-0 max-h-[50vh] list-none overflow-auto p-1">
          <For each={items()} fallback={<li class="px-3 py-2 text-ink-faint">no command matches</li>}>
            {(c, n) => (
              <li>
                <button
                  class="flex w-full justify-between px-3 py-1.5"
                  classList={{ "bg-gold-wash text-gold-leaf": n() === i(), "text-ink-dim": n() !== i() }}
                  onClick={bind(c.id, undefined, "menu")}
                  onMouseEnter={() => setI(n())}
                >
                  <span>{c.title}</span>
                  <span class="text-ink-faint">{c.keys?.join(" · ")}</span>
                </button>
              </li>
            )}
          </For>
        </ul>
      </div>
    </div>
  );
}
