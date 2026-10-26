// The tracker: the viewer's own feature list (srv/todo.py, ~/.dotfiles/canopy/todo). Needs you →
// doing → the ranked queue → waiting. /next ranks it and writes each item's next steps.
import { For, Show } from "solid-js";
import { model, tkey } from "./model";
import { keyOf } from "./registry";
import { renderMarkdown } from "./review/markdown";
import { bind } from "./runner";
import { world } from "./store";
import { SECTION_TITLES } from "./tracker";
import type { TodoItem } from "./types";
import { todoOpen } from "./ui";

const KIND: Record<string, string> = { build: "build", fix: "fix", decide: "decide", look: "look into" };

function Row(props: { t: TodoItem }) {
  const on = () => model.selected() === tkey(props.t.id);
  const open = () => todoOpen().has(props.t.id);
  return (
    <div data-row={tkey(props.t.id)}>
      <div
        class="group flex min-h-[38px] cursor-default items-center gap-3 border-l-2 px-4 pl-[42px] transition-colors duration-150"
        classList={{ "border-gold-leaf bg-gold-wash": on(), "border-transparent hover:bg-vellum-raise": !on() }}
        onClick={bind("cursor.set", tkey(props.t.id))}
        onDblClick={bind("todo.open", props.t.id)}
      >
        <span class="w-7 shrink-0 text-right font-mono text-[11px] text-ink-faint">{props.t.rank ?? ""}</span>
        <span class="min-w-0 flex-1 truncate font-display text-[17px]" classList={{ "text-gold-leaf": on(), "text-ink": !on() }}>
          {props.t.title}
          <Show when={props.t.problems?.length}>
            <span class="ml-2 text-[12px] text-ember" title={props.t.problems!.join("\n")}>⚠</span>
          </Show>
        </span>
        <span class="hidden w-[34%] shrink-0 truncate text-ink-dim md:inline">{props.t.state === "waiting" ? `⏳ ${props.t.waiting}` : props.t.why}</span>
        <span class="w-[190px] shrink-0 whitespace-nowrap text-right text-[11px] text-ink-faint">
          {KIND[props.t.kind] ?? props.t.kind} · {props.t.area} · {props.t.size}
        </span>
      </div>
      <Show when={open()}>
        <div class="mb-3 ml-[86px] mr-4 border-l border-rule pl-4 text-[13px] text-ink-dim">
          <p class="m-0 mb-2 text-ink">{props.t.why}</p>
          <Show when={props.t.problems?.length}>
            <p class="m-0 mb-2 text-ember">{props.t.problems!.join(" · ")}</p>
          </Show>
          <Show when={props.t.blocked_by?.length}>
            <p class="m-0 mb-2">after: {props.t.blocked_by!.join(", ")}</p>
          </Show>
          <div class="md" innerHTML={renderMarkdown(props.t.body || "")} />
          <Show when={props.t.links?.length}>
            <p class="m-0 mt-2 text-ink-faint">{props.t.links!.join(" · ")}</p>
          </Show>
          <p class="m-0 mt-2 font-mono text-[11px] text-ink-faint">
            {props.t.id} · since {props.t.created} · /next {props.t.id}
          </p>
        </div>
      </Show>
    </div>
  );
}

export default function Todo() {
  const open = () => model.todos().reduce((n, s) => n + s.items.length, 0);
  return (
    <Show when={world.ready} fallback={<p class="px-4 pl-11 text-ink-faint">reading the tracker…</p>}>
      <div data-paint="todo" class="relative mx-auto max-w-[1080px]">
        <p class="m-0 mb-6 px-4 pl-11 text-ink-dim">
          {open()} open · <code class="text-ink-faint">/next</code> ranks
        </p>
        <For each={model.todos()} fallback={<p class="px-4 pl-11 text-ink-faint">nothing tracked</p>}>
          {(s) => (
            <section class="mb-7">
              <h2 class="m-0 mb-1 px-4 pl-11 text-[11px] font-normal uppercase tracking-[0.14em]" classList={{ "text-gold-leaf": s.section === "decide", "text-ink-faint": s.section !== "decide" }}>
                {SECTION_TITLES[s.section]} · {s.items.length}
              </h2>
              <For each={s.items}>{(t) => <Row t={t} />}</For>
            </section>
          )}
        </For>
      </div>
    </Show>
  );
}
