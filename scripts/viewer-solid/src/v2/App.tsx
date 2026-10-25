import { Match, Show, Switch } from "solid-js";
import Dashboard from "./Dashboard";
import Forests from "./Forests";
import KeySheet from "./KeySheet";
import Menu from "./Menu";
import Review from "./review/Review";
import Todo from "./Todo";
import { surface } from "./router";
import { note } from "./runner";
import { world } from "./store";
import { pendingKeys } from "./ui";

export default function App() {
  return (
    <div class="min-h-full">
      <header class="flex items-baseline gap-3 px-4 pb-6 pt-5">
        <span class="font-display text-[22px] text-gold-leaf">canopy</span>
        <span class="text-ink-faint">{surface().title.toLowerCase()}</span>
        <span class="flex-1" />
        <span class="text-ink-faint">space · commands &nbsp; ? · keys</span>
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
          <Match when={surface().id === "dashboard"}>
            <Dashboard />
          </Match>
          <Match when={surface().id === "review"}>
            <Review />
          </Match>
          <Match when={surface().id === "todo"}>
            <Todo />
          </Match>
        </Switch>
      </main>
      <footer class="fixed inset-x-0 bottom-0 flex gap-4 border-t border-vellum-edge bg-vellum-night px-4 py-2 text-ink-dim">
        <Show when={note()}>
          <span role="status">{note()}</span>
        </Show>
        <span class="flex-1" />
        <Show when={pendingKeys()}>
          <kbd class="font-mono text-gold-leaf">{pendingKeys()} …</kbd>
        </Show>
      </footer>
      <Menu />
      <KeySheet />
    </div>
  );
}
