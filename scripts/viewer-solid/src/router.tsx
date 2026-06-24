// The viewer's router — a hand-rolled, typed replacement for @solidjs/router's HashRouter.
//
// Why hand-rolled: the app has exactly four destinations, and three of them (forest /
// standalone / review) were previously crammed into one `/*forest` splat and pulled apart
// downstream by regex (/^review\/pr-\d+$/) and string-shape guesses. A discriminated
// ViewerLocation makes the identity explicit at the boundary, so no consumer has to sniff a
// name to know what it's looking at. We still drive the URL hash (static-deploy keeps working
// — the server never sees the path).
//
//   #/work  #/forests  #/watching        → home, a named tab
//   #/forest/<name>[?node=<branch>]       → a forest project (node = the active branch)
//   #/branch/<branch...>[?node=<branch>]  → a pinned standalone (slashes ride the path tail)
//   #/review/<pr>[?node=<branch>]         → an imported review PR
//
// Forest/branch names carry slashes, so they travel raw in the path tail (joined back with
// "/"); `node` carries slashes too, so it rides as a search param the way it always has.
import { createContext, useContext, createSignal, onCleanup, type JSX } from "solid-js";

export type HomeTab = "work" | "forests" | "watching";
export const HOME_TABS: HomeTab[] = ["work", "forests", "watching"];

export type ViewerLocation =
  | { kind: "home"; tab: HomeTab }
  | { kind: "forest"; name: string; node?: string }
  | { kind: "standalone"; branch: string; node?: string }
  | { kind: "review"; pr: number; node?: string };

const isHomeTab = (s: string): s is HomeTab => (HOME_TABS as string[]).includes(s);

// hash (with or without leading "#") → typed location. Anything unrecognised falls home.
export function parseHash(raw: string): ViewerLocation {
  const [path, query = ""] = raw.replace(/^#/, "").split("?");
  const node = new URLSearchParams(query).get("node") || undefined;
  const [head, ...rest] = path.split("/").filter(Boolean);
  const tail = rest.join("/"); // forest / branch names keep their slashes

  if (!head || isHomeTab(head)) {
    return { kind: "home", tab: head ? (head as HomeTab) : "work" };
  }
  if (head === "forest" && tail) {
    return { kind: "forest", name: tail, node };
  }
  if (head === "branch" && tail) {
    return { kind: "standalone", branch: tail, node };
  }
  if (head === "review" && rest.length) {
    const pr = parseInt(rest[0], 10);
    if (Number.isFinite(pr)) {
      return { kind: "review", pr, node };
    }
  }
  return { kind: "home", tab: "work" };
}

// typed location → hash (leading "#"), for both href and navigate.
export function buildHash(loc: ViewerLocation): string {
  const q = (n?: string) => (n ? "?node=" + encodeURIComponent(n) : "");
  switch (loc.kind) {
    case "home":
      return "#/" + loc.tab;
    case "forest":
      return "#/forest/" + loc.name + q(loc.node);
    case "standalone":
      return "#/branch/" + loc.branch + q(loc.node);
    case "review":
      return "#/review/" + loc.pr + q(loc.node);
  }
}

// The server identifies a node by its branch/project name. ViewerLocation stores a review as
// a number for clean URLs, so map back to the name the backend expects — a review node's real
// local branch IS "review/pr-<N>". Home has no node target, so "".
export function forestKey(loc: ViewerLocation): string {
  switch (loc.kind) {
    case "home":
      return "";
    case "forest":
      return loc.name;
    case "standalone":
      return loc.branch;
    case "review":
      return "review/pr-" + loc.pr;
  }
}

// Re-target the active node within the current location (the j/k spine walk, click-to-open).
export function withNode(loc: ViewerLocation, node: string): ViewerLocation {
  return loc.kind === "home" ? loc : { ...loc, node };
}

interface RouterCtx {
  location: () => ViewerLocation;
  navigate: (loc: ViewerLocation, opts?: { replace?: boolean }) => void;
}
const Ctx = createContext<RouterCtx>();

export function RouterProvider(props: { children: JSX.Element }) {
  const read = (): ViewerLocation => parseHash(window.location.hash);
  const [location, setLocation] = createSignal<ViewerLocation>(read());
  const onHash = () => setLocation(read());
  window.addEventListener("hashchange", onHash);
  onCleanup(() => window.removeEventListener("hashchange", onHash));

  const navigate = (loc: ViewerLocation, opts?: { replace?: boolean }) => {
    const h = buildHash(loc);
    if (opts?.replace) {
      // replaceState doesn't fire hashchange — push the new location through by hand.
      history.replaceState(null, "", h);
      setLocation(read());
    } else {
      window.location.hash = h; // fires hashchange → onHash → setLocation
    }
  };

  return <Ctx.Provider value={{ location, navigate }}>{props.children}</Ctx.Provider>;
}

export function useViewerLocation(): RouterCtx {
  const c = useContext(Ctx);
  if (!c) {
    throw new Error("useViewerLocation must be used within a RouterProvider");
  }
  return c;
}

// A hash anchor that routes through navigate(). The href is a real "#/…" so middle/⌘-click
// opens a new tab and copy-link works; a plain left-click is intercepted for in-app nav.
export function Link(props: {
  to: ViewerLocation;
  class?: string;
  classList?: Record<string, boolean | undefined>;
  title?: string;
  children: JSX.Element;
  onClick?: (e: MouseEvent) => void;
}): JSX.Element {
  const { navigate } = useViewerLocation();
  return (
    <a
      href={buildHash(props.to)}
      class={props.class}
      classList={props.classList}
      title={props.title}
      onClick={(e) => {
        if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) {
          return; // let the browser handle new-tab / new-window
        }
        e.preventDefault();
        navigate(props.to);
        props.onClick?.(e);
      }}
    >
      {props.children}
    </a>
  );
}
