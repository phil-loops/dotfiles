// The space k popover: the type in markdown, or a line saying what tsgo is doing (or why not).
import { Match, Show, Switch } from "solid-js";
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
        </Switch>
      </div>
    </Show>
  );
}
