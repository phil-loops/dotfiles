// A forest's story (the forest page's other face, tab): the feature told top to bottom — its thesis,
// then every chapter in merge order, what already landed included, then what's in flight, then
// what's left. One plain line each; e opens a chapter's why (a landed PR's squash message on main,
// a live branch's commit messages), l a live chapter's review page.
import { createResource, For, Show } from "solid-js";
import { bare, stripPlan } from "./outlineHints";
import Commits from "./Commits";
import { atRepo, bkey, dkey, model, type BranchView } from "./model";
import { bind } from "./runner";
import { leaf, SHIP } from "./ship";
import { getJSON } from "./sync";
import type { Landed } from "./types";
import { wordsOpen } from "./ui";

const day = (iso: string) => new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric" });

function Chapter(props: { n: number; k: string; line: string; side: string; dim?: boolean; children?: unknown }) {
  const on = () => model.selected() === props.k;
  return (
    <li
      data-row={props.k}
      class="cursor-default border-l-2 py-2 pl-10 pr-4 transition-colors duration-150"
      classList={{ "border-gold-leaf bg-gold-wash": on(), "border-transparent hover:bg-vellum-raise": !on() }}
      onClick={bind("cursor.set", props.k)}
    >
      <div class="flex items-baseline gap-3">
        <span class="w-5 shrink-0 text-right text-[11px] text-ink-faint">{props.n}</span>
        <span class="min-w-0 flex-1" classList={{ "text-gold-leaf": on(), "text-ink": !on() && !props.dim, "text-ink-dim": !on() && props.dim }}>
          {props.line}
        </span>
        <span class="shrink-0 whitespace-nowrap text-[11px] text-ink-faint">{props.side}</span>
      </div>
      <Show when={props.children}>
        <div class="ml-8 mt-2 text-[12.5px]">{props.children as never}</div>
      </Show>
    </li>
  );
}

function LandedWhy(props: { l: Landed }) {
  const [w] = createResource(
    () => props.l.id,
    () => getJSON<{ subject: string; body: string }>(atRepo(props.l.repo, `/landed-why?pr=${props.l.pr}`)).catch(() => null),
  );
  return (
    <Show when={w()} fallback={<p class="m-0 text-ink-faint">{w.loading ? "reading main…" : "not on main yet"}</p>}>
      <pre class="m-0 whitespace-pre-wrap font-mono text-[12px] text-ink-dim">{stripPlan(w()!.body) || "no body"}</pre>
    </Show>
  );
}

export default function Story(props: { pid: string }) {
  const landed = () => model.landedOf(props.pid);
  const live = () => (model.forests().get(props.pid)?.branches ?? []).filter((v) => v.st.ship !== "landed");
  const inFlight = () => live().filter((v) => v.pr || v.b.pushed !== "local");
  const left = () => live().filter((v) => !v.pr && v.b.pushed === "local");
  const sideOf = (v: BranchView) => [v.pr ? `#${v.pr.number}` : "", SHIP[v.st.ship].word].filter(Boolean).join(" · ");
  const liveChapter = (v: BranchView, n: number) => (
    <Chapter n={n} k={bkey(v.b.id)} line={v.b.description || leaf(v.b.name)} side={sideOf(v)}>
      {wordsOpen().has(v.b.id) ? <Commits branchId={v.b.id} readOnly /> : undefined}
    </Chapter>
  );
  const section = (title: string, count: number) => (
    <h2 class="m-0 mb-1 mt-6 px-4 pl-11 text-[11px] font-normal uppercase tracking-[0.14em] text-ink-faint">
      {title} · {count}
    </h2>
  );
  return (
    <div>
      <Show when={landed().length}>
        {section("Landed", landed().length)}
        <ol class="m-0 list-none p-0">
          <For each={landed()}>
            {(l, i) => (
              <Chapter n={i() + 1} k={dkey(l.id)} line={bare(l.title)} side={`#${l.pr} · merged ${day(l.at)}`} dim>
                {wordsOpen().has(dkey(l.id)) ? <LandedWhy l={l} /> : undefined}
              </Chapter>
            )}
          </For>
        </ol>
      </Show>
      <Show when={inFlight().length}>
        {section("In flight", inFlight().length)}
        <ol class="m-0 list-none p-0">
          <For each={inFlight()}>{(v, i) => liveChapter(v, landed().length + i() + 1)}</For>
        </ol>
      </Show>
      <Show when={left().length}>
        {section("Left", left().length)}
        <ol class="m-0 list-none p-0">
          <For each={left()}>{(v, i) => liveChapter(v, landed().length + inFlight().length + i() + 1)}</For>
        </ol>
      </Show>
    </div>
  );
}
