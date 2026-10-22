import { Match, Switch } from "solid-js";
import Forests from "./Forests";
import { surface } from "./router";
import { world } from "./store";

export default function App() {
  return (
    <div class="min-h-full">
      <header class="flex items-baseline gap-3 px-4 pb-6 pt-5">
        <span class="font-display text-[22px] text-gold-leaf">canopy</span>
        <span class="text-ink-faint">{surface().title.toLowerCase()}</span>
        <span class="flex-1" />
        <span
          class="inline-block h-[7px] w-[7px] rounded-full"
          classList={{ "bg-patina": world.conn === "live", "bg-ink-faint": world.conn === "connecting", "bg-ember": world.conn === "down" }}
          title={world.conn === "live" ? "live" : world.conn === "down" ? "reconnecting to the server" : "connecting"}
        />
      </header>
      <main class="pb-16">
        <Switch>
          <Match when={surface().id === "forests"}>
            <Forests />
          </Match>
        </Switch>
      </main>
    </div>
  );
}
