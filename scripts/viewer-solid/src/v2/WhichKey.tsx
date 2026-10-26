// Helix's which-key: a half-typed prefix (space, g) opens a box in the corner listing what can follow
// it here, from the registry, the narrowest scope's meaning winning as the keymap's own rule does.
import { createMemo, For, Show } from "solid-js";
import { liveScopes, targetFor } from "./model";
import { commands, glyph } from "./registry";
import { pendingKeys } from "./ui";

/** A title's first clause, lowercase: "Show outdated conversations" → "show outdated conversations". */
const short = (title: string) => {
  const t = title.split(/ — | \(|, or /)[0].trim();
  return t.charAt(0).toLowerCase() + t.slice(1);
};

export default function WhichKey() {
  const rows = createMemo(() => {
    const prefix = pendingKeys();
    if (!prefix) return [];
    const live = liveScopes();
    const rank = (s: string) => (s === "global" ? live.length : live.indexOf(s));
    const seen = new Set<string>();
    return commands()
      .filter((c) => (c.scope === "global" || live.includes(c.scope)) && (!c.available || c.available(targetFor(c.scope))))
      .sort((a, b) => rank(a.scope) - rank(b.scope))
      .flatMap((c) =>
        (c.keys ?? [])
          .filter((k) => k.startsWith(`${prefix} `))
          .map((k) => ({ key: k.slice(prefix.length + 1), what: short(c.title) })),
      )
      .filter((r) => !seen.has(r.key) && !!seen.add(r.key))
      .sort((a, b) => a.key.toLowerCase().localeCompare(b.key.toLowerCase()) || a.key.localeCompare(b.key));
  });
  return (
    <Show when={pendingKeys()}>
      <div data-paint="whichkey" class="fixed bottom-4 right-4 z-30 min-w-[220px] max-w-[min(420px,92vw)] border border-rule bg-vellum-raise px-3 py-2 text-[12px] shadow-2xl">
        <div class="mb-1 font-mono text-gold-leaf">{glyph(pendingKeys())}</div>
        <Show when={rows().length} fallback={<div class="text-ink-faint">nothing here</div>}>
          <For each={rows()}>
            {(r) => (
              <div class="flex gap-3 py-px">
                <kbd class="w-8 shrink-0 font-mono text-gold-leaf">{glyph(r.key)}</kbd>
                <span class="text-ink-dim">{r.what}</span>
              </div>
            )}
          </For>
        </Show>
      </div>
    </Show>
  );
}
