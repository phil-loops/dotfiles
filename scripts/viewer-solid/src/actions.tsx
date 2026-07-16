// The viewer's contextual-action model — one descriptor + one renderer for every "do something
// to this row/branch" affordance. Before this, each context (forest row, watch row, node header)
// hand-rolled its own buttons, its own two-click arm, and its own preventDefault/stopPropagation
// dance inside a row that's also a <Link>. The pyramids of nested <Show> that picked which button
// to render were the worst of it. Here a context just computes an Action[] and hands it to
// <ActionBar>; the arm pattern lives in useArm, and the click-guard lives in one place.
//
// Visuals: an Action carries an optional `class` so it reuses the existing per-context styling
// (.watch-pin, …) — the model is behaviour, not a restyle.
import { createSignal, For, onCleanup, type JSX } from "solid-js";

export interface Action {
  id: string;
  label: () => string;
  // Shown in place of label() while the action is armed (two-click confirm), e.g. "restack?".
  armLabel?: () => string;
  title?: string;
  class?: string; // reuse an existing button style; falls back to .action-btn
  // Tailwind actions swap whole class strings per state — the armed/running markers carry no styles.
  armedClass?: string;
  runningClass?: string;
  // mid-flight (request in progress) → disabled + a "running" class for the existing spinners.
  busy?: () => boolean;
  disabled?: () => boolean;
  arm?: boolean; // require a confirming second click before run() fires
  run: () => void;
}

// Two-click confirm: the first click on an id arms it for `ms`; a second click within the window
// fires run() and disarms. Arming a different id moves the arm. Centralises what Home.arm and
// NodeActions.armSquash each reinvented.
export function useArm(ms = 3000): {
  armed: () => string | null;
  trigger: (id: string, run: () => void) => void;
} {
  const [armed, setArmed] = createSignal<string | null>(null);
  let t: ReturnType<typeof setTimeout> | undefined;
  onCleanup(() => clearTimeout(t));
  const trigger = (id: string, run: () => void) => {
    if (armed() === id) {
      clearTimeout(t);
      setArmed(null);
      run();
      return;
    }
    setArmed(id);
    clearTimeout(t);
    t = setTimeout(() => setArmed(null), ms);
  };
  return { armed, trigger };
}

// Renders a row of actions. Each button swallows the click (so an enclosing <Link> row doesn't
// navigate) and routes arm-required actions through a single useArm.
// Fallback styling when an Action carries no `class`. The old .action-btn.running opacity
// (0.7) never rendered — running always co-occurs with :disabled, whose 0.5 won the tie —
// so only disabled:opacity-50 survives translation.
const AB = "action-btn flex-none cursor-pointer rounded-[7px] border px-[11px] py-[3px] text-[11px] leading-[1.55] tracking-[0.03em] transition-[border-color,color,background] duration-[120ms] disabled:cursor-default disabled:opacity-50";
const AB_QUIET = `${AB} border-transparent bg-transparent text-patina hover:border-patina`;
const AB_ARMED = `${AB} border-del bg-del-bg text-del`;
const AB_RUNNING = `${AB} border-transparent bg-transparent text-patina`;

export function ActionBar(props: { actions: Action[]; class?: string }): JSX.Element {
  const { armed, trigger } = useArm();
  return (
    <div class={props.class ?? "action-bar inline-flex items-center gap-2"}>
      <For each={props.actions}>
        {(a) => (
          <button
            class={
              (a.busy?.() && (a.runningClass ?? AB_RUNNING)) ||
              (armed() === a.id && (a.armedClass ?? AB_ARMED)) ||
              (a.class ?? AB_QUIET)
            }
            classList={{ armed: armed() === a.id, running: !!a.busy?.() }}
            title={a.title}
            disabled={a.busy?.() || a.disabled?.()}
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              if (a.arm) {
                trigger(a.id, a.run);
              } else {
                a.run();
              }
            }}
          >
            {armed() === a.id && a.armLabel ? a.armLabel() : a.label()}
          </button>
        )}
      </For>
    </div>
  );
}
