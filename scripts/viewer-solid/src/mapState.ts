import { createSignal } from "solid-js";

// The forest map as an overlay over whatever page you're on — `m` anywhere. Module scope so the
// key handler, the node page's hint and any future entry point share one open/closed state, and
// so the overlay remembers which forest it last showed while you move between pages.
export type MapTarget = { name: string; repo?: string };

const [mapTarget, setMapTarget] = createSignal<MapTarget | null>(null);

export { mapTarget };
export const mapOpen = () => !!mapTarget();
export const openMap = (t: MapTarget) => setMapTarget(t);
export const closeMap = () => setMapTarget(null);
