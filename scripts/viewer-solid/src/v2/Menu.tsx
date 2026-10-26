// `space`: every command in reach, filterable. Enter runs the highlighted one.
import { createMemo, createSignal, For, onMount, Show } from "solid-js";
import { liveScopes, targetFor } from "./model";
import { commands, glyph } from "./registry";
import { bind, dispatch } from "./runner";
import { menuOpen, setMenuOpen } from "./ui";

/** The palette's sections, in this order; within one, what the cursor is on comes first. */
const GROUPS = ["move", "view", "review", "words & push", "go"] as const;
function groupOf(id: string): (typeof GROUPS)[number] {
  if (/^(nav|place)\.|^help\.|^branch\.(pr|open)$|^forest\.page$|^review\.(definition|open|finish)$/.test(id)) return "go";
  if (/^(cursor|focus|history|commit)\.|^review\.(down|up|top|bottom|thread\.(next|prev)|file\.(next|prev)|leave|back)$|^forest\.(expand|collapse|leave)$|^todo\.(up|down)$/.test(id)) return "move";
  if (/^review\.(tab|split|outdated|map|filter|types|history)|^(forest\.face|ready\.toggle|archive\.toggle|dashboard\.range|todo\.open)$/.test(id)) return "view";
  if (/words|^story\.|push|^forest\.launch$|^project\.|^hold\.|^todo\.|^undo$/.test(id)) return "words & push";
  return "review";
}

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
    const scopes = liveScopes();
    const needle = q().toLowerCase();
    return commands().filter(
      (c) =>
        !c.quiet &&
        scopes.includes(c.scope) &&
        (!c.available || c.available(targetFor(c.scope))) &&
        (c.title + " " + c.id).toLowerCase().includes(needle),
    ).sort((a, b) => GROUPS.indexOf(groupOf(a.id)) - GROUPS.indexOf(groupOf(b.id)) || scopes.indexOf(a.scope) - scopes.indexOf(b.scope));
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
          <For each={items()} fallback={<li class="px-3 py-2 text-ink-faint">no match</li>}>
            {(c, n) => (
              <li>
                <Show when={n() === 0 || groupOf(items()[n() - 1].id) !== groupOf(c.id)}>
                  <div class="px-3 pb-0.5 pt-2 text-[10.5px] uppercase tracking-[0.12em] text-ink-faint">{groupOf(c.id)}</div>
                </Show>
                <button
                  class="flex w-full justify-between px-3 py-1.5"
                  classList={{ "bg-gold-wash text-gold-leaf": n() === i(), "text-ink-dim": n() !== i() }}
                  onClick={bind(c.id, undefined, "menu")}
                  onMouseEnter={() => setI(n())}
                >
                  <span>{c.title}</span>
                  <span class="font-mono text-ink-faint">{c.keys?.map(glyph).join(" · ")}</span>
                </button>
              </li>
            )}
          </For>
        </ul>
      </div>
    </div>
  );
}
