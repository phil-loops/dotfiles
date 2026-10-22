// The router — the one way the page changes surface, and so the one place navigation is measured:
// every navigation emits `nav {from, to, paintMs}`, paintMs being input → the frame that paints the
// surface's `[data-paint]` marker (its meaningful content, not its loading state).
import { createSignal } from "solid-js";
import { contentPaint, emit } from "./telemetry";

export interface Surface {
  id: string;
  path: string;
  title: string;
  /** v1 surfaces this replaces, for the dashboard's side-by-side */
  v1?: string[];
}

export const BASE = "/v2";
export const SURFACES: Surface[] = [
  { id: "forests", path: BASE, title: "Forests", v1: ["home"] },
  { id: "dashboard", path: `${BASE}/dashboard`, title: "Dashboard" },
];

const match = (pathname: string): Surface =>
  SURFACES.find((s) => s.path === pathname.replace(/\/+$/, "")) ?? SURFACES[0];

const [surface, setSurface] = createSignal<Surface>(match(location.pathname));
export { surface };

function measure(from: string, to: string, t0: number): void {
  void contentPaint(to, t0).then((paintMs) => emit({ type: "nav", from, to, paintMs }));
}

export function navigate(path: string, e?: Event): void {
  const next = match(path);
  const from = surface().id;
  if (next.id === from) return;
  const t0 = e?.timeStamp ?? performance.now();
  history.pushState(null, "", next.path);
  setSurface(next);
  measure(from, next.id, t0);
}

/** Leave v2 for a page it doesn't have yet (v1's branch page, Work, Wiki…): recorded as a
 *  navigation to "v1:<path>" — the page unloads, so there is no paint to time. */
export function leave(path: string): void {
  emit({ type: "nav", from: surface().id, to: `v1:${path.split("?")[0]}`, paintMs: null });
  location.assign(path);
}

/** Measure the entry paint (from the navigation's start) and follow back/forward. */
export function startRouter(): void {
  measure("", surface().id, 0);
  window.addEventListener("popstate", () => {
    const from = surface().id;
    const next = match(location.pathname);
    setSurface(next);
    if (next.id !== from) measure(from, next.id, performance.now());
  });
}
