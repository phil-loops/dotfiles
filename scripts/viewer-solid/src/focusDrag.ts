import { createSignal } from "solid-js";

// Cross-section drag: a forest row in flight toward the focus lane. ForestsList publishes the
// pointer as it moves; FocusLane registers the drop handler (hit-test + pin-at-position). A
// module store because the gesture spans two sibling components.
export type RowDrag = { repo: string; name: string; x: number; y: number };

export const [rowDrag, setRowDrag] = createSignal<RowDrag | null>(null);

let dropFn: ((d: RowDrag) => boolean) | null = null;
export function registerLaneDrop(fn: (d: RowDrag) => boolean): () => void {
  dropFn = fn;
  return () => { if (dropFn === fn) dropFn = null; };
}
export const dropOnLane = (d: RowDrag): boolean => (dropFn ? dropFn(d) : false);
