// The viewer's router — a hand-rolled, typed replacement for @solidjs/router.
//
// Why hand-rolled: the app has exactly four destinations, and three of them (forest /
// standalone / review) were previously crammed into one `/*forest` splat and pulled apart
// downstream by regex (/^review\/pr-\d+$/) and string-shape guesses. A discriminated
// ViewerLocation makes the identity explicit at the boundary, so no consumer has to sniff a
// name to know what it's looking at. Real History-API paths (not hash) — clean URLs; the
// server serves index.html for any app route (SPA fallback) so deep-links + refresh resolve.
//
//   /work  /forests  /watching          → home, a named tab
//   /forests/<project>[/<branch...>]     → a forest: project + active node (a branch), both in path
//   /branch/<branch...>                  → a pinned standalone (single node)
//   /review/<pr>                         → an imported review PR (single node)
//
// A forest project tag is a single segment; the active node (a branch) is the path tail, slashes
// and all. Putting both in the path means the URL fully identifies the view — no ?node= query.
// `/forests` with no project is the home tab; `/forests/<project>` is a forest (collection/item).
import { createContext, useContext, createSignal, onCleanup, type JSX } from "solid-js";

export type HomeTab = "work" | "forests" | "watching";
export const HOME_TABS: HomeTab[] = ["work", "forests", "watching"];

export type ViewerLocation =
  | { kind: "home"; tab: HomeTab }
  | { kind: "forest"; name: string; node?: string; repo?: string }
  | { kind: "standalone"; branch: string; node?: string }
  | { kind: "review"; pr: number; node?: string }
  | { kind: "push"; branch: string };

const isHomeTab = (s: string): s is HomeTab => (HOME_TABS as string[]).includes(s);

// The registry repo names, injected into index.html by the server (window.__VIEWER_REPOS__).
// Lets the parser tell a <repo> path segment from a <project> one without an async fetch.
export function knownRepos(): Set<string> {
  const w = window as unknown as { __VIEWER_REPOS__?: string[] };
  return new Set(w.__VIEWER_REPOS__ ?? ["loops", "monotoad"]);
}

// pathname + search → typed location. Anything unrecognised falls home.
export function parseLocation(pathname: string, search: string): ViewerLocation {
  const [head, ...rest] = pathname.split("/").filter(Boolean);

  if (!head) {
    // legacy launch entry: `loops stack web <name>` opens /?branch=<name> — honour it as a forest
    // (RouterProvider canonicalises the URL to /forests/<name> on load).
    const branch = new URLSearchParams(search).get("branch");
    return branch ? { kind: "forest", name: branch } : { kind: "home", tab: "work" };
  }
  // /forests is the home tab; /forests/<project>[/<branch...>] is a forest — project is one
  // segment, the active node (a branch, slashes and all) is the tail.
  if (head === "forests" && rest.length) {
    // repo is the TOP of the hierarchy: /forests/<repo>/<project>/<branch> when the first segment
    // names a known repo; otherwise loops-implicit /forests/<project>/<branch> (short form kept).
    let repo: string | undefined;
    let segs = rest;
    if (knownRepos().has(rest[0])) {
      repo = rest[0] === "loops" ? undefined : rest[0];
      segs = rest.slice(1);
    }
    const [project, ...nodeParts] = segs;
    if (!project) {
      return { kind: "home", tab: "forests" };
    }
    return { kind: "forest", name: project, node: nodeParts.length ? nodeParts.join("/") : undefined, repo };
  }
  if (isHomeTab(head)) {
    return { kind: "home", tab: head };
  }
  if (head === "branch" && rest.length) {
    return { kind: "standalone", branch: rest.join("/") };
  }
  // /push/<branch...> — the mobile prepare-to-push card for one branch
  if (head === "push" && rest.length) {
    return { kind: "push", branch: rest.join("/") };
  }
  if (head === "review" && rest.length) {
    const pr = parseInt(rest[0], 10);
    if (Number.isFinite(pr)) {
      return { kind: "review", pr };
    }
  }
  return { kind: "home", tab: "work" };
}

// typed location → path (leading "/"), for both href and navigate.
export function buildPath(loc: ViewerLocation): string {
  switch (loc.kind) {
    case "home":
      return "/" + loc.tab;
    case "forest":
      return "/forests/" + (loc.repo && loc.repo !== "loops" ? loc.repo + "/" : "")
        + loc.name + (loc.node ? "/" + loc.node : "");
    case "standalone":
      return "/branch/" + loc.branch;
    case "review":
      return "/review/" + loc.pr;
    case "push":
      return "/push/" + loc.branch;
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
    case "push":
      return loc.branch;
  }
}

// Re-target the active node within the current location (the j/k spine walk, click-to-open).
export function withNode(loc: ViewerLocation, node: string): ViewerLocation {
  return loc.kind === "home" || loc.kind === "push" ? loc : { ...loc, node };
}

// The repo a location belongs to — only a forest can live in a non-loops repo; everything
// else is the launched (loops) repo. Used to keep repo on forest nav that rebuilds the location.
export function forestRepo(loc: ViewerLocation): string | undefined {
  return loc.kind === "forest" ? loc.repo : undefined;
}

interface RouterCtx {
  location: () => ViewerLocation;
  navigate: (loc: ViewerLocation, opts?: { replace?: boolean }) => void;
}
const Ctx = createContext<RouterCtx>();

export function RouterProvider(props: { children: JSX.Element }) {
  const read = (): ViewerLocation => parseLocation(window.location.pathname, window.location.search);
  const [location, setLocation] = createSignal<ViewerLocation>(read());
  // Canonicalise a legacy launch URL (`/?branch=<name>`) to its clean path so the bar reads right.
  if (window.location.pathname === "/" && new URLSearchParams(window.location.search).get("branch")) {
    history.replaceState(null, "", buildPath(location()));
  }
  // Back/forward fire popstate; pushState/replaceState do NOT, so navigate() syncs by hand.
  const onPop = () => setLocation(read());
  window.addEventListener("popstate", onPop);
  onCleanup(() => window.removeEventListener("popstate", onPop));

  const navigate = (loc: ViewerLocation, opts?: { replace?: boolean }) => {
    const p = buildPath(loc);
    if (opts?.replace) {
      history.replaceState(null, "", p);
    } else {
      history.pushState(null, "", p);
    }
    setLocation(read());
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

// A real-path anchor that routes through navigate(). The href is a true "/…" path so
// middle/⌘-click opens a new tab and copy-link works; a plain left-click is intercepted for
// in-app nav (no full reload).
export function Link(props: {
  to: ViewerLocation;
  class?: string;
  classList?: Record<string, boolean | undefined>;
  title?: string;
  children: JSX.Element;
  onClick?: (e: MouseEvent) => void;
  onMouseEnter?: (e: MouseEvent) => void;
  onMouseLeave?: (e: MouseEvent) => void;
}): JSX.Element {
  const { navigate } = useViewerLocation();
  return (
    <a
      href={buildPath(props.to)}
      class={props.class}
      classList={props.classList}
      title={props.title}
      onMouseEnter={(e) => props.onMouseEnter?.(e)}
      onMouseLeave={(e) => props.onMouseLeave?.(e)}
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
