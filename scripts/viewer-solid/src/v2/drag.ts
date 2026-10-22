// Dragging a focus forest by its grip: the forest follows the pointer, the ones it passes step
// aside, and letting go runs `focus.move` — the command C-j/C-k reach too, so a drag is measured
// and undoable like any other reorder.
import { dispatch } from "./runner";
import { drag, setDrag } from "./ui";

/** the forest just let go of — it lands where the pointer left it, so the slide-into-place skips it */
export let dropped: string | undefined;

export function startDrag(id: string, from: number, down: PointerEvent): void {
  if (from < 0 || down.button !== 0) return;
  down.preventDefault();
  // each focus forest is one block (its row plus any open spine); the drop slot is the block whose
  // middle the dragged block's middle has passed
  const blocks = [...document.querySelectorAll<HTMLElement>("[data-focus-block]")].map((el) => el.getBoundingClientRect());
  const me = blocks[from];
  if (!me) return;
  const y0 = down.clientY;
  setDrag({ id, from, to: from, dy: 0, h: me.height });
  const onMove = (e: PointerEvent) => {
    const dy = e.clientY - y0;
    const mid = me.top + me.height / 2 + dy;
    let to = from;
    blocks.forEach((r, i) => {
      if (i > from && mid > r.top + r.height / 2) to = i;
      if (i < from && mid < r.top + r.height / 2 && to === from) to = i;
    });
    setDrag({ id, from, to, dy, h: me.height });
  };
  const end = (e: PointerEvent) => {
    window.removeEventListener("pointermove", onMove);
    window.removeEventListener("pointerup", end);
    window.removeEventListener("pointercancel", end);
    const d = drag();
    setDrag(undefined);
    dropped = `p:${id}`;
    requestAnimationFrame(() => requestAnimationFrame(() => (dropped = undefined)));
    if (e.type === "pointerup" && d && d.to !== d.from) dispatch("focus.move", "drag", { target: id, arg: d.to, event: e });
  };
  window.addEventListener("pointermove", onMove);
  window.addEventListener("pointerup", end);
  window.addEventListener("pointercancel", end);
}

/** How far a focus forest at `i` steps aside while another is dragged past it. */
export function shiftFor(i: number, id: string): number {
  const d = drag();
  if (!d) return 0;
  if (d.id === id) return d.dy;
  if (d.from < i && i <= d.to) return -d.h;
  if (d.to <= i && i < d.from) return d.h;
  return 0;
}
