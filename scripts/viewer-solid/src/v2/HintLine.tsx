// The quiet line at the bottom of every page: the few keys that act on what the cursor is on right
// now — the first of `?`'s "Right now", from the same registry walk (sheetNow) — so they're learnt
// by seeing them. Holding ⇧ shows the capitals' layer, a half-typed chord (g …) what can follow;
// the key that just fired lights for a moment, and one that had nothing to do says so. A key drops
// out of the normal line once it's been pressed often enough to be known (hints.ts).
import { createMemo, For, Show } from "solid-js";
import { known, short } from "./hints";
import { liveScopes, targetFor } from "./model";
import { commands, getCommand, glyph } from "./registry";
import { surface } from "./router";
import { fired } from "./runner";
import { sheetNow } from "./sheet";
import { pendingKeys, shiftHeld } from "./ui";

const MAX = 5;
type Hint = { id: string; key: string; title: string };

/** A command's one word for the line. */
const word = (id: string, title: string) => getCommand(id)?.label ?? short(title);

/** Opposites as one hint — "j/k line", "n/⇧n thread" — the partner folded into the first. */
function paired(items: Hint[]): Hint[] {
  const out: Hint[] = [];
  const gone = new Set<string>();
  for (const h of items) {
    if (gone.has(h.id)) continue;
    const partner = getCommand(h.id)?.pair;
    const other = partner ? items.find((x) => x.id === partner) : undefined;
    if (other) {
      gone.add(other.id);
      out.push({ ...h, key: `${h.key}/${other.key}` });
    } else out.push(h);
  }
  return out.filter((h) => !gone.has(h.id));
}

export default function HintLine() {
  const cmds = () =>
    commands()
      .filter((c) => c.keys?.length)
      .map((c) => ({ id: c.id, title: c.title, scope: c.scope, keys: c.keys!, available: !c.available || c.available(targetFor(c.scope)) }));
  const hints = createMemo<{ layer: string; items: Hint[] }>(() => {
    const live = liveScopes();
    const prefix = pendingKeys();
    if (prefix) {
      // what can follow a half-typed chord, in the scopes live here
      const items = cmds()
        .filter((c) => (c.scope === "global" || live.includes(c.scope)) && c.available)
        .flatMap((c) => c.keys.filter((k) => k.startsWith(`${prefix} `)).map((k) => ({ id: c.id, key: glyph(k.slice(prefix.length + 1)), title: word(c.id, c.title) })));
      return { layer: `${glyph(prefix)} …`, items };
    }
    const g = sheetNow(surface().id, live, cmds());
    if (shiftHeld()) {
      const capital = (k: string) => /^[A-Z]$/.test(k);
      const items = [...g.now, ...g.everywhere]
        .flatMap((l) => l.cmd.keys.filter(capital).map((k) => ({ id: l.cmd.id, key: glyph(k), title: word(l.cmd.id, l.cmd.title) })));
      return { layer: "", items: paired(items) };
    }
    const all = g.now.map((l) => ({ id: l.cmd.id, key: glyph(l.key.split(" · ")[0]), title: word(l.cmd.id, l.cmd.title) }));
    // a pair is known only when both halves are
    const fresh = (h: Hint) => !known(h.id) || !!(getCommand(h.id)?.pair && !known(getCommand(h.id)!.pair!));
    return { layer: "", items: paired(all.filter(fresh)).slice(0, MAX) };
  });
  const missed = () => {
    const f = fired();
    return f && !f.ok ? glyph(getCommand(f.id)?.keys?.[0] ?? "") : "";
  };
  return (
    <span class="truncate text-[11.5px] text-ink-faint" aria-label="keys for what the cursor is on">
      <Show when={missed()}>
        <span class="mr-3 text-ink-dim">
          <span class="font-mono">{missed()}</span> · nothing here
        </span>
      </Show>
      <Show when={hints().layer}>
        <span class="mr-2 font-mono text-gold-leaf">{hints().layer}</span>
      </Show>
      <For each={hints().items}>
        {(h, i) => (
          <>
            {i() ? " · " : ""}
            <span class="rv-hintkey font-mono text-ink-dim" classList={{ "rv-fired": !!fired()?.ok && fired()!.id === h.id }}>
              {h.key}
            </span>{" "}
            {h.title}
          </>
        )}
      </For>
    </span>
  );
}
