// `?`: every key, generated from the registry — so it can't drift from what the keys do.
import { For, Show } from "solid-js";
import { commands } from "./registry";
import { bind } from "./runner";
import { sheetOpen } from "./ui";

const SCOPES = [
  { id: "global", title: "Everywhere" },
  { id: "project", title: "On a forest" },
];

export default function KeySheet() {
  return (
    <Show when={sheetOpen()}>
      <div class="fixed inset-0 z-20 flex items-center justify-center">
        <div class="absolute inset-0 bg-vellum-night/70" onClick={bind("overlay.close")} />
        <div class="relative w-[min(560px,92vw)] border border-rule bg-vellum-raise px-6 py-5">
          <h2 class="m-0 mb-3 font-display text-[20px] font-normal text-ink">Keys</h2>
          <For each={SCOPES}>
            {(s) => (
              <section class="mb-3">
                <h3 class="m-0 mb-1 text-[11px] font-normal uppercase tracking-[0.12em] text-ink-faint">{s.title}</h3>
                <For each={commands().filter((c) => c.scope === s.id && c.keys?.length)}>
                  {(c) => (
                    <div class="flex justify-between py-0.5">
                      <span class="text-ink-dim">{c.title}</span>
                      <kbd class="font-mono text-gold-leaf">{c.keys!.join(" · ")}</kbd>
                    </div>
                  )}
                </For>
              </section>
            )}
          </For>
        </div>
      </div>
    </Show>
  );
}
