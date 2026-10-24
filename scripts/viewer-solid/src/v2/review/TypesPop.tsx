// The K / g d popover: the type in markdown, a "loading" line with what tsgo is doing, or the
// definitions that aren't in this diff, each with a few lines of source.
import { For, Match, Show, Switch } from "solid-js";
import { renderMarkdown } from "./markdown";
import { pop } from "./types";

export default function TypesPop() {
  const style = () => {
    const p = pop()!;
    return { left: `${Math.min(p.x, innerWidth - 560)}px`, top: `${Math.min(p.y + 6, innerHeight - 80)}px` };
  };
  return (
    <Show when={pop()}>
      <div class="rv-pop" style={style()} role="tooltip">
        <Switch>
          <Match when={pop()!.kind === "wait"}>
            <span class="text-ink-dim animate-breathe">{(pop() as { text: string }).text}</span>
          </Match>
          <Match when={pop()!.kind === "note"}>
            <span class="text-ink-dim">{(pop() as { text: string }).text}</span>
          </Match>
          <Match when={pop()!.kind === "hover"}>
            <div class="md" innerHTML={renderMarkdown((pop() as { md: string }).md)} />
          </Match>
          <Match when={pop()!.kind === "defs"}>
            <For each={(pop() as { locs: { path: string; line: number; text: string }[] }).locs}>
              {(l) => (
                <div class="rv-def">
                  <div class="text-ink-faint">
                    {l.path}:{l.line}
                  </div>
                  <pre>{l.text}</pre>
                </div>
              )}
            </For>
          </Match>
        </Switch>
      </div>
    </Show>
  );
}
