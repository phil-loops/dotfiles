// Motion that explains where things went: rows glide to their new place (FLIP), rows that appear
// unfold in, a state that changes settles. 150–200 ms on the compositor — it plays while the next
// keypress is already being handled — and none of it under prefers-reduced-motion.
import { createEffect, on } from "solid-js";
import { dropped } from "./drag";

const EASE = "cubic-bezier(.2,.8,.2,1)";
const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
let bootedAt = Infinity;
/** Nothing animates on the first paint — motion is for change, not arrival. */
export const boot = () => (bootedAt = performance.now() + 400);
const live = () => !reduced.matches && performance.now() > bootedAt;

/** Glide every `[data-row]` under `root` from where it was to where it is whenever `track` moves. */
export function flip(root: () => HTMLElement | undefined, track: () => unknown): void {
  let last = new Map<string, number>();
  createEffect(
    on(track, () => {
      const el = root();
      if (!el) return;
      const rows = [...el.querySelectorAll<HTMLElement>("[data-row]")];
      const tops = new Map(rows.map((r) => [r.dataset.row!, r.offsetTop]));
      if (live() && last.size) {
        let entering = 0;
        for (const r of rows) {
          const k = r.dataset.row!;
          const was = last.get(k);
          const top = tops.get(k)!;
          if (k === dropped) continue;
          if (was === undefined) {
            r.animate([{ opacity: 0, transform: "translateY(-6px)" }, { opacity: 1, transform: "none" }], {
              duration: 180, delay: Math.min(entering++, 8) * 18, easing: EASE, fill: "backwards",
            });
          } else if (Math.abs(was - top) > 1) {
            r.animate([{ transform: `translateY(${was - top}px)` }, { transform: "none" }], { duration: 190, easing: EASE });
          }
        }
      }
      last = tops;
    }),
  );
}

// Refs run before the element is attached, and Chrome strands an animation started on a detached
// element at its first keyframe (opacity stuck at 0.2) — so these start on the next frame.

/** A ref: the element settles in when it replaces another (a state word changing). */
export function settle(el: HTMLElement): void {
  if (live()) requestAnimationFrame(() => el.isConnected && el.animate([{ opacity: 0.2, transform: "translateY(3px)" }, { opacity: 1, transform: "none" }], { duration: 200, easing: EASE }));
}

/** A ref: the archive count catches a row that just left for it. */
export function catchIt(el: HTMLElement): void {
  if (live()) requestAnimationFrame(() => el.isConnected && el.animate([{ transform: "translateY(-5px)", color: "var(--color-gold-leaf)" }, { transform: "none" }], { duration: 420, easing: EASE }));
}
