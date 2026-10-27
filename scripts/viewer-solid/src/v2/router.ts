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
  /** the path is a prefix: what follows it is the surface's argument (the review page's branch) */
  arg?: boolean;
}

export const BASE = "/v2";
export const SURFACES: Surface[] = [
  { id: "forests", path: BASE, title: "Forests", v1: ["home"] },
  { id: "dashboard", path: `${BASE}/dashboard`, title: "Dashboard" },
  { id: "review", path: `${BASE}/b`, title: "Review", v1: ["branch"], arg: true },
  { id: "todo", path: `${BASE}/todo`, title: "Todo" },
  { id: "forest", path: `${BASE}/p`, title: "Forest", arg: true },
  { id: "machine", path: `${BASE}/machine`, title: "Machine", v1: ["machine"] },
];

const match = (pathname: string): Surface => {
  const p = pathname.replace(/\/+$/, "");
  return SURFACES.find((s) => (s.arg ? p.startsWith(s.path + "/") : s.path === p)) ?? SURFACES[0];
};
const argOf = (pathname: string, s: Surface): string =>
  s.arg ? decodeURIComponent(pathname.replace(/\/+$/, "").slice(s.path.length + 1)) : "";

const [surface, setSurface] = createSignal<Surface>(match(location.pathname));
/** the surface's argument: on the review page, "<repo>/<branch>" */
const [routeArg, setRouteArg] = createSignal(argOf(location.pathname, surface()));
export { surface, routeArg };

function measure(from: string, to: string, t0: number): void {
  void contentPaint(to, t0).then((paintMs) => emit({ type: "nav", from, to, paintMs }));
}

export function navigate(path: string, e?: Event): void {
  const next = match(path);
  const arg = argOf(path, next);
  const from = surface().id;
  if (next.id === from && arg === routeArg()) return;
  const t0 = e?.timeStamp ?? performance.now();
  history.pushState(null, "", next.arg ? path : next.path);
  setSurface(next);
  setRouteArg(arg);
  measure(from, next.id, t0);
}

/** The review page of a branch. */
/** One forest's page: every branch in merge order, what it does, where it stands. */
export const forestPath = (repo: string, project: string) => `${BASE}/p/${encodeURIComponent(repo)}/${encodeURIComponent(project)}`;
export const reviewPath = (repo: string, branch: string) => `${BASE}/b/${encodeURIComponent(repo)}/${branch.split("/").map(encodeURIComponent).join("/")}`;

/** A forest's whole diff against main, on the review page: its integration ref (refs/stack/<project>-integration)
 *  reads like a branch there — the server's /node builds it fresh and diffs it against main. */
export const integrationRef = (project: string) => `refs/stack/${project}-integration`;
/** The forest a review page's ref integrates, or undefined for a real branch. */
export const integrationOf = (name: string): string | undefined => /^refs\/stack\/(.+)-integration$/.exec(name)?.[1];

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
    const was = routeArg();
    const next = match(location.pathname);
    setSurface(next);
    setRouteArg(argOf(location.pathname, next));
    if (next.id !== from || routeArg() !== was) measure(from, next.id, performance.now());
  });
}
