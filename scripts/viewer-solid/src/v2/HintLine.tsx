// The quiet line at the bottom of every page: the few keys that act on what the cursor is on right
// now — the first of `?`'s "Right now", from the same registry walk (sheetNow) — so they're learnt
// by seeing them. A key drops out once it's been pressed often enough to be known (hints.ts).
import { createMemo, For } from "solid-js";
import { known, short } from "./hints";
import { liveScopes, targetFor } from "./model";
import { commands, glyph } from "./registry";
import { surface } from "./router";
import { sheetNow } from "./sheet";

const MAX = 5;

export default function HintLine() {
  const lines = createMemo(() =>
    sheetNow(
      surface().id,
      liveScopes(),
      commands()
        .filter((c) => c.keys?.length)
        .map((c) => ({ id: c.id, title: c.title, scope: c.scope, keys: c.keys!, available: !c.available || c.available(targetFor(c.scope)) })),
    )
      .now.filter((l) => !known(l.cmd.id))
      .slice(0, MAX),
  );
  return (
    <span class="truncate text-[11.5px] text-ink-faint" aria-label="keys for what the cursor is on">
      <For each={lines()}>
        {(l, i) => (
          <>
            {i() ? " · " : ""}
            <span class="font-mono text-ink-dim">{glyph(l.key.split(" · ")[0])}</span> {short(l.cmd.title)}
          </>
        )}
      </For>
    </span>
  );
}
