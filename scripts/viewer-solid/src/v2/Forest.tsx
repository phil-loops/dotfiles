// One forest's page (/v2/p/<repo>/<project>): every branch in merge order with what it does in full —
// its description and commit outline — and where it stands: ship state, gates, PR, open threads.
// `l` opens a branch's review page, `h` goes back to Forests.
import { createMemo, For, Show } from "solid-js";
import { bkey, model, type BranchView } from "./model";
import { keyOf } from "./registry";
import { bind } from "./runner";
import { leaf, SHIP } from "./ship";
import Commits from "./Commits";
import Story from "./Story";
import { list, view, world } from "./store";
import { forestFace, wordsOpen } from "./ui";

const GATES: Record<string, string> = { green: "gates green", red: "gates red", running: "gates running", stale: "gates stale", none: "not gated" };

function openThreads(v: BranchView): number {
  return list("thread").filter((t) => t.repo === v.b.repo && t.branch === v.b.name && !t.resolved && !t.outdated).length;
}

function Branch(props: { v: BranchView }) {
  const b = () => props.v.b;
  const on = () => model.selected() === bkey(b().id);
  const landed = () => props.v.st.ship === "landed";
  const facts = createMemo(() => {
    const out: string[] = [];
    const pr = props.v.pr;
    if (pr) out.push(`#${pr.number}${pr.draft ? " draft" : ""}${pr.approvals ? ` · ${pr.approvals} approval${pr.approvals === 1 ? "" : "s"}` : ""}`);
    else if (b().commits) out.push(b().gates === "red" && b().redGates.length ? `red: ${b().redGates.join(", ")}` : GATES[b().gates]);
    if (b().pushed === "ahead") out.push(`${b().ahead} to push`);
    const n = openThreads(props.v);
    if (n) out.push(`${n} open`);
    if (props.v.st.ship === "approved" && props.v.st.waiting[0]) out.push(`waiting on ${props.v.st.waiting[0].label}`);
    return out;
  });
  /** the keys for the row under the cursor: ↵ does its next step, l always opens it */
  const caption = () => {
    const act = props.v.st.action;
    const go = act === "push" ? "push" : act === "pr" ? "open the PR" : "open";
    return [`${keyOf("row.primary")} ${go}`, act === "push" || act === "pr" ? `${keyOf("branch.open")} open` : "", `${keyOf("forest.words")} words`].filter(Boolean).join(" · ");
  };
  return (
    <li
      data-row={bkey(b().id)}
      class="cursor-default border-l-2 py-3 pl-10 pr-4 transition-colors duration-150"
      classList={{ "border-gold-leaf bg-gold-wash": on(), "border-transparent hover:bg-vellum-raise": !on(), "opacity-60": landed() }}
      onClick={bind("cursor.set", bkey(b().id))}
      onDblClick={bind("branch.open", b().id)}
    >
      <div class="flex items-baseline gap-3">
        <span class="w-5 shrink-0 text-right text-[11px] text-ink-faint">{b().order < 999 ? b().order : ""}</span>
        <span class="min-w-0 flex-1 truncate font-display text-[17px]" classList={{ "text-gold-leaf": on(), "text-ink": !on() }} title={b().name}>
          {leaf(b().name)}
        </span>
        <Show when={on()}>
          <span class="shrink-0 whitespace-nowrap text-[11px] text-ink-faint">{caption()}</span>
        </Show>
        <span class="shrink-0 whitespace-nowrap text-ink-dim">
          {SHIP[props.v.st.ship].glyph} {SHIP[props.v.st.ship].word}
        </span>
      </div>
      <div class="ml-8 mt-1">
        <p class="m-0 text-ink-dim" classList={{ "text-ink-faint italic": !b().description }}>
          {b().description || "no description"}
        </p>
        <Show
          when={wordsOpen().has(b().id)}
          fallback={
            <Show when={b().outline?.length}>
              <ol class="m-0 mt-1.5 list-none p-0 text-[12px] text-ink-faint">
                <For each={b().outline}>{(s) => <li class="truncate before:mr-2 before:content-['·']">{s}</li>}</For>
              </ol>
            </Show>
          }
        >
          <div class="mt-2 text-[12.5px]">
            <Commits branchId={b().id} readOnly />
          </div>
        </Show>
        <Show when={facts().length}>
          <p class="m-0 mt-1.5 text-[11px]" classList={{ "text-del": !props.v.pr && b().gates === "red", "text-ink-faint": !!props.v.pr || b().gates !== "red" }}>
            {facts().join(" · ")}
          </p>
        </Show>
      </div>
    </li>
  );
}

export default function Forest() {
  const p = () => (model.pageProject() ? view("project", model.pageProject()!) : undefined);
  const f = () => (model.pageProject() ? model.forests().get(model.pageProject()!) : undefined);
  const counts = () => {
    const bs = f()?.branches ?? [];
    const by = (s: string) => bs.filter((v) => v.st.ship === s).length;
    return [`${bs.length} branch${bs.length === 1 ? "" : "es"}`, by("landed") && `${by("landed")} landed`, f()?.ready.length && `${f()!.ready.length} ready`]
      .filter(Boolean)
      .join(" · ");
  };
  return (
    <Show when={world.ready} fallback={<p class="px-4 pl-11 text-ink-faint">reading the forest…</p>}>
      <Show when={p()} fallback={<p class="px-4 pl-11 text-ink-faint">no such forest</p>}>
        <div data-paint="forest" class="relative mx-auto max-w-[980px]">
          <header class="mb-6 px-4 pl-11">
            <h1 class="m-0 font-display text-[26px] font-normal text-ink">
              {p()!.name}
              <Show when={p()!.ticket}>
                <span class="ml-3 align-middle font-mono text-[12px] text-ink-faint">{p()!.ticket}</span>
              </Show>
            </h1>
            <Show when={p()!.summary}>
              <p class="m-0 mt-1 text-ink-dim">{p()!.summary}</p>
            </Show>
            <p class="m-0 mt-2 text-[12px] text-ink-faint">
              {p()!.state} · {counts()}
            </p>
          </header>
          <Show
            when={forestFace() === "story"}
            fallback={
              <ol class="m-0 list-none p-0">
                <For each={f()?.branches ?? []}>{(v) => <Branch v={v} />}</For>
              </ol>
            }
          >
            <Story pid={model.pageProject()!} />
          </Show>
        </div>
      </Show>
    </Show>
  );
}
