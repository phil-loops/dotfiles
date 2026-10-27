// `space`: every command in reach, filterable, then the branches, forests, wiki pages and concepts the text finds. Enter runs the highlighted one.
import { createMemo, createSignal, For, onMount, Show } from "solid-js";
import { finds } from "./find";
import { liveScopes, targetFor } from "./model";
import { commands, glyph } from "./registry";
import { bind, dispatch } from "./runner";
import { list } from "./store";
import { getJSON } from "./sync";
import type { Branch, Entities, Pr } from "./types";
import { menuOpen, setMenuOpen } from "./ui";
import { wiki } from "./wikiread";
import { tutor } from "./tutoring";

/** The palette's sections, in this order; within one, what the cursor is on comes first. */
const GROUPS = ["move", "view", "review", "words & push", "machine", "wiki", "tutor", "go", "forests", "branches", "wiki pages", "concepts"] as const;
type Group = (typeof GROUPS)[number];
function groupOf(id: string): Group {
  if (/^machine\./.test(id)) return "machine";
  if (/^wiki\./.test(id)) return "wiki";
  if (/^tutor\./.test(id)) return "tutor";
  if (/^(nav|place)\.|^help\.|^branch\.(pr|open)$|^forest\.page$|^review\.(definition|open|finish)$/.test(id)) return "go";
  if (/^(cursor|focus|history|commit)\.|^review\.(down|up|top|bottom|thread\.(next|prev)|file\.(next|prev)|leave|back)$|^forest\.(expand|collapse|leave)$|^todo\.(up|down)$/.test(id)) return "move";
  if (/^review\.(tab|split|outdated|map|filter|types|history)|^(forest\.face|ready\.toggle|archive\.toggle|dashboard\.range|todo\.open)$/.test(id)) return "view";
  if (/words|^story\.|push|^forest\.launch$|^project\.|^hold\.|^todo\.|^undo$/.test(id)) return "words & push";
  return "review";
}

interface Row {
  id: string;
  arg?: string;
  title: string;
  side: string;
  group: Group;
}

/** Every branch and PR, archived forests' too — the live store leaves those out, the finder can't. */
async function everything(): Promise<{ branch: Record<string, Branch>; pr: Record<string, Pr> }> {
  const s = await getJSON<{ entities: Pick<Entities, "branch" | "pr"> }>("/state?archived=1");
  return s.entities;
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
  const [all, setAll] = createSignal<{ branch: Record<string, Branch>; pr: Record<string, Pr> }>({ branch: {}, pr: {} });
  let input!: HTMLInputElement;
  onMount(() => {
    input.focus();
    everything().then(setAll, () => {});
    wiki.load();
    tutor.load();
  });
  const merged = <T extends { id: string }>(live: T[], more: Record<string, T>): T[] => {
    const have = new Set(live.map((x) => x.id));
    return [...live, ...Object.values(more).filter((x) => !have.has(x.id))];
  };
  const cmds = createMemo(() => {
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
  const items = createMemo<Row[]>(() => [
    ...cmds().map((c) => ({ id: c.id, title: c.title, side: c.keys?.map(glyph).join(" · ") ?? "", group: groupOf(c.id) })),
    ...finds(q(), { branches: merged(list("branch"), all().branch), projects: list("project"), prs: merged(list("pr"), all().pr), pages: wiki.pages(), concepts: Object.values(tutor.learn()?.concepts ?? {}) }).map((f) => ({
      id: f.cmd,
      arg: f.id,
      title: f.title,
      side: f.sub,
      group: ({ "find.forest": "forests", "find.wiki": "wiki pages", "find.concept": "concepts", "find.branch": "branches" } as const)[f.cmd],
    })),
  ]);
  const via = () => (q() ? "palette" : "menu");
  const run = (r: Row, e: Event) => dispatch(r.id, via(), { event: e, arg: r.arg });
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
      const r = items()[i()];
      if (r) run(r, e);
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
          placeholder="run a command, or find a branch, a page, a concept…"
          class="w-full border-0 border-b border-rule bg-transparent px-4 py-3 outline-none placeholder:text-ink-faint"
        />
        <ul class="m-0 max-h-[50vh] list-none overflow-auto p-1">
          <For each={items()} fallback={<li class="px-3 py-2 text-ink-faint">no match</li>}>
            {(r, n) => (
              <li>
                <Show when={n() === 0 || items()[n() - 1].group !== r.group}>
                  <div class="px-3 pb-0.5 pt-2 text-[10.5px] uppercase tracking-[0.12em] text-ink-faint">{r.group}</div>
                </Show>
                <button
                  class="flex w-full justify-between gap-3 px-3 py-1.5"
                  classList={{ "bg-gold-wash text-gold-leaf": n() === i(), "text-ink-dim": n() !== i() }}
                  onClick={bind(r.id, undefined, "menu", r.arg)}
                  onMouseEnter={() => setI(n())}
                >
                  <span class="min-w-0 truncate text-left">{r.title}</span>
                  <span class="shrink-0 font-mono text-ink-faint">{r.side}</span>
                </button>
              </li>
            )}
          </For>
        </ul>
      </div>
    </div>
  );
}
