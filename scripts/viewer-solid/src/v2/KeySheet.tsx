// `?`: what you can do right now — the keys that act on the thing under the cursor, as the commands
// they'd run here, then what works anywhere, then this page's keys that do nothing at the moment.
// Generated from the registry, so it can't drift from what the keys do.
import { For, Show } from "solid-js";
import { liveScopes, model, targetFor } from "./model";
import { commands, glyph } from "./registry";
import { page, sideLine } from "./review/page";
import { surface } from "./router";
import { bind } from "./runner";
import { sheetNow, type SheetLine } from "./sheet";
import { view } from "./store";
import { sheetOpen } from "./ui";
import { customized, keyProblems } from "./userkeys";

/** What a scope's commands act on right now, in words. */
function labelOf(scope: string): string {
  const h = page.here();
  switch (scope) {
    case "branch":
      return view("branch", model.selectedBranch()!)?.name ?? "this branch";
    case "project":
      return `the forest ${view("project", model.selectedProject()!)?.name ?? ""}`.trim();
    case "forest":
      return `${view("project", model.pageProject() ?? "")?.name ?? "this forest"}'s page`;
    case "row":
      return model.selectedBranch() ? labelOf("branch") : labelOf("project");
    case "item":
      return view("todo", model.selectedItem()!)?.title ?? "this item";
    case "line":
      return h?.kind === "line" ? `${h.path.split("/").pop()}:${sideLine(h.row).line}` : "this line";
    case "thread":
      return "this conversation";
    case "gap":
      return "the hidden lines";
    case "pending":
      return "your draft";
    default:
      return `the ${surface().title} page`;
  }
}
const hereLabel = () => labelOf(liveScopes()[0]);

/** Right-now lines under a heading per target: the branch, then its forest, then the page. */
const byTarget = (lines: SheetLine[]) => {
  const out: { label: string; lines: SheetLine[] }[] = [];
  for (const l of lines) {
    const label = labelOf(l.cmd.scope);
    const same = out.find((g) => g.label === label);
    if (same) same.lines.push(l);
    else out.push({ label, lines: [l] });
  }
  return out;
};

function Lines(props: { lines: SheetLine[]; dim?: boolean }) {
  return (
    <For each={props.lines}>
      {(l) => (
        <div class="flex justify-between gap-4 py-0.5">
          <span class={props.dim ? "text-ink-faint" : "text-ink-dim"}>{l.cmd.title}</span>
          <kbd class={`shrink-0 font-mono ${props.dim ? "text-ink-faint" : "text-gold-leaf"} ${customized.has(l.cmd.id) ? "underline decoration-dotted" : ""}`}>{l.key.split(" · ").map(glyph).join(" · ")}</kbd>
        </div>
      )}
    </For>
  );
}

export default function KeySheet() {
  const groups = () =>
    sheetNow(
      surface().id,
      liveScopes(),
      commands()
        .filter((c) => c.keys?.length)
        .map((c) => ({ id: c.id, title: c.title, scope: c.scope, keys: c.keys!, available: !c.available || c.available(targetFor(c.scope)) })),
    );
  const hints = () => commands().filter((c) => c.hint?.length && liveScopes().includes(c.scope));
  return (
    <Show when={sheetOpen()}>
      <div class="fixed inset-0 z-20 flex items-center justify-center">
        <div class="absolute inset-0 bg-vellum-night/70" onClick={bind("overlay.close")} />
        <div class="relative max-h-[86vh] w-[min(620px,92vw)] overflow-auto border border-rule bg-vellum-raise px-6 py-5">
          <h2 class="m-0 mb-3 font-display text-[20px] font-normal text-ink">
            Right now <span class="text-ink-faint">· {hereLabel()}</span>
          </h2>
          <Show when={keyProblems.length}>
            <ul class="m-0 mb-3 list-none border-l-2 border-gold-leaf p-0 pl-3 text-[12px] text-ink">
              <For each={keyProblems}>{(p) => <li>{p}</li>}</For>
            </ul>
          </Show>
          <section class="mb-4">
            <Show when={groups().now.length || hints().length} fallback={<p class="m-0 text-ink-faint">nothing under the cursor</p>}>
              <For each={byTarget(groups().now)}>
                {(g) => (
                  <div class="mb-2">
                    <h3 class="m-0 mb-0.5 text-[11px] font-normal uppercase tracking-[0.12em] text-gold-leaf">{g.label}</h3>
                    <Lines lines={g.lines} />
                  </div>
                )}
              </For>
              <For each={hints()}>
                {(c) => (
                  <div class="flex justify-between gap-4 py-0.5">
                    <span class="text-ink-dim">{c.title}</span>
                    <kbd class="shrink-0 font-mono text-gold-leaf">{c.hint!.join(" · ")}</kbd>
                  </div>
                )}
              </For>
            </Show>
          </section>
          <section class="mb-4">
            <h3 class="m-0 mb-1 text-[11px] font-normal uppercase tracking-[0.12em] text-ink-faint">Anywhere</h3>
            <Lines lines={groups().everywhere} />
          </section>
          <Show when={groups().notNow.length}>
            <section>
              <h3 class="m-0 mb-1 text-[11px] font-normal uppercase tracking-[0.12em] text-ink-faint">not here</h3>
              <Lines lines={groups().notNow} dim />
            </section>
          </Show>
          <p class="m-0 mt-4 text-[11px] text-ink-faint">
            yours: <code>canopy/keys.toml</code> (<span class="underline decoration-dotted">underlined</span>)
          </p>
        </div>
      </div>
    </Show>
  );
}
