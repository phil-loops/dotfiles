// `?`: the keys that work here, generated from the registry — so it can't drift from what the keys do.
import { For, Show } from "solid-js";
import { liveScopes, targetFor } from "./model";
import { commands } from "./registry";
import { surface } from "./router";
import { bind } from "./runner";
import { SCOPE_TITLES, sheetSections } from "./sheet";
import { sheetOpen } from "./ui";


export default function KeySheet() {
  return (
    <Show when={sheetOpen()}>
      <div class="fixed inset-0 z-20 flex items-center justify-center">
        <div class="absolute inset-0 bg-vellum-night/70" onClick={bind("overlay.close")} />
        <div class="relative max-h-[86vh] w-[min(620px,92vw)] overflow-auto border border-rule bg-vellum-raise px-6 py-5">
          <h2 class="m-0 mb-3 font-display text-[20px] font-normal text-ink">Keys <span class="text-ink-faint">· {surface().title}</span></h2>
          <For each={sheetSections(surface().id, liveScopes())}>
            {(s) => (
              <section class="mb-3">
                <h3 class={`m-0 mb-1 text-[11px] font-normal uppercase tracking-[0.12em] ${s.live ? "text-gold-leaf" : "text-ink-faint"}`}>{SCOPE_TITLES[s.scope]}</h3>
                <For each={commands().filter((c) => c.scope === s.scope && (c.keys?.length || c.hint?.length))}>
                  {(c) => (
                    <div class="flex justify-between py-0.5">
                      <span class={!s.live || !c.available || c.available(targetFor(c.scope)) ? "text-ink-dim" : "text-ink-faint"}>{c.title}</span>
                      <kbd class="font-mono text-gold-leaf">{(c.keys ?? c.hint)!.join(" · ")}</kbd>
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
