// Phase 0's Forests: a plain list straight from the store, kept live by the server's patches.
// Phase 1 designs the real page.
import { For, Show } from "solid-js";
import { model } from "./model";
import { world } from "./store";
import type { Project } from "./types";
import { showArchive } from "./ui";

function Row(props: { p: Project }) {
  const on = () => model.selected() === props.p.id;
  return (
    <li
      data-row={props.p.id}
      class="group flex cursor-default items-baseline gap-4 border-l-2 px-4 py-2 transition-colors duration-150"
      classList={{ "border-gold-leaf bg-gold-wash": on(), "border-transparent hover:bg-vellum-raise": !on() }}
    >
      <span class="min-w-[12ch] text-ink" classList={{ "text-gold-leaf": on() }}>
        {props.p.name}
      </span>
      <span class="flex-1 truncate text-ink-dim">{props.p.summary}</span>
      <span class="text-ink-faint">
        {props.p.size} {props.p.size === 1 ? "branch" : "branches"}
      </span>
    </li>
  );
}

function Section(props: { title: string; rows: Project[]; empty: string }) {
  return (
    <section class="mb-8">
      <h2 class="m-0 mb-2 px-4 font-display text-[19px] font-normal text-ink-dim">
        {props.title} <span class="font-mono text-[12px] text-ink-faint">{props.rows.length}</span>
      </h2>
      <ul class="m-0 list-none p-0">
        <For each={props.rows} fallback={<li class="px-4 py-2 text-ink-faint">{props.empty}</li>}>
          {(p) => <Row p={p} />}
        </For>
      </ul>
    </section>
  );
}

export default function Forests() {
  const p = () => model.projects();
  return (
    <Show when={world.ready} fallback={<p class="px-4 text-ink-faint">reading the forests…</p>}>
      <div data-paint="forests">
        <Section title="Focus" rows={p().focus} empty="nothing in focus — f on a forest puts it here" />
        <Section title="Workbench" rows={p().workbench} empty="the workbench is clear" />
        <Show
          when={showArchive()}
          fallback={
            <p class="px-4 text-ink-faint">archive · {p().archive.length}</p>
          }
        >
          <Section title="Archive" rows={p().archive} empty="the archive is empty" />
        </Show>
      </div>
    </Show>
  );
}
