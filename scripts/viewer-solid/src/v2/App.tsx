import { createEffect, Match, on, Show, Switch } from "solid-js";
import Dashboard from "./Dashboard";
import Forest from "./Forest";
import Forests from "./Forests";
import KeySheet from "./KeySheet";
import { model } from "./model";
import Menu from "./Menu";
import { page } from "./review/page";
import Review from "./review/Review";
import Todo from "./Todo";
import { surface } from "./router";
import { bind, note } from "./runner";
import { view, world } from "./store";
import WhichKey from "./WhichKey";

export default function App() {
  // The cursor stays on screen: whichever page's rows it moves through, the selected one scrolls
  // into view when it leaves it (the review page follows its own cursor the same way).
  createEffect(
    on(
      () => model.selected(),
      (k) => {
        if (!k) return;
        requestAnimationFrame(() => document.querySelector(`[data-row="${CSS.escape(k)}"]`)?.scrollIntoView({ block: "nearest" }));
      },
    ),
  );
  return (
    <div class="min-h-full">
      <header class="flex items-baseline gap-2 px-4 pb-4 pt-3 text-[12px] text-ink-faint">
        <Crumbs />
        <span class="flex-1" />
        <Show when={world.conn !== "live"}>
          <span
            class="inline-block h-[7px] w-[7px] self-center rounded-full"
            classList={{ "bg-ink-faint": world.conn === "connecting", "bg-ember": world.conn === "down" }}
            title={world.conn === "down" ? "reconnecting to the server" : "connecting"}
          />
        </Show>
      </header>
      <main class="pb-10">
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
          <Match when={surface().id === "forest"}>
            <Forest />
          </Match>
          <Match when={surface().id === "todo"}>
            <Todo />
          </Match>
        </Switch>
      </main>
      <Show when={note()}>
        <div role="status" class="fixed bottom-4 left-4 z-30 max-w-[60vw] border border-rule bg-vellum-raise px-3 py-1.5 text-[12px] text-ink-dim shadow-xl">
          {note()}
        </div>
      </Show>
      <WhichKey />
      <Menu />
      <KeySheet />
    </div>
  );
}

/** Where you are, as the ladder `h` climbs: canopy › forest › branch. */
function Crumbs() {
  const branch = () => (surface().id === "review" ? view("branch", page.id() ?? "") : undefined);
  const forest = () =>
    surface().id === "forest" ? view("project", model.pageProject() ?? "") : branch() ? view("project", branch()!.project) : undefined;
  const sep = () => <span class="text-ink-faint/60">›</span>;
  return (
    <nav class="flex min-w-0 items-baseline gap-2" aria-label="where you are">
      <button class="font-display text-[17px] text-gold-leaf" onClick={bind(surface().id === "forest" ? "forest.leave" : "nav.forests")}>
        canopy
      </button>
      <Switch>
        <Match when={surface().id === "forests"}>{null}</Match>
        <Match when={forest()}>
          {sep()}
          <Show when={branch()} fallback={<span class="truncate text-ink-dim">{forest()!.name}</span>}>
            <button class="truncate hover:text-ink-dim" onClick={bind("review.leave")}>
              {forest()!.name}
            </button>
            {sep()}
            <span class="truncate text-ink-dim">{branch()!.name}</span>
          </Show>
        </Match>
        <Match when={true}>
          {sep()}
          <span class="text-ink-dim">{surface().title.toLowerCase()}</span>
        </Match>
      </Switch>
    </nav>
  );
}
