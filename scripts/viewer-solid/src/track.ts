import { canMutate } from "./provider";
import { parseLocation } from "./router";

// The original fetch, captured before installFetchTracking() wraps window.fetch — so the
// telemetry POST below never re-enters the wrapper (and keeps working if other code wraps fetch).
const realFetch = window.fetch.bind(window);

// Who this tab is, sent as headers on every same-origin call so the server's request log and
// usage log can tell this page from a Claude curl or the extension. navigator.webdriver is set
// under Puppeteer/Playwright — a headless run must never read as Phil.
export const ACTOR = navigator.webdriver ? "headless" : "browser";
// One id per page load: two tabs on one page (the audit's 442 exact-duplicate events) and a
// reload become separable, and every event joins its page's nav chain.
export const PAGE_LOAD = Math.random().toString(36).slice(2, 8);
const sameOrigin = (url: URL) => url.origin === location.origin;
let ridSeq = 0;
// X-Request-Id lands in the server's request log, so a client timing joins the server's line.
const withIdentity = (headers: HeadersInit | undefined, rid?: string): Headers => {
  const h = new Headers(headers);
  h.set("X-Stack-Actor", ACTOR);
  if (rid) h.set("X-Request-Id", rid);
  return h;
};

// Fire-and-forget local usage telemetry → POST /track (the server appends one JSONL line
// to .git/stack-usage.jsonl). Single-user, never leaves the machine, never committed.
// Live mode only — a static snapshot has no server to post to. NEVER awaited and NEVER
// allowed to throw into the UI: a dropped event is fine, a broken action is not.
export function track(type: string, data: Record<string, unknown> = {}): void {
  if (!canMutate) return;
  try {
    void realFetch("/track", {
      method: "POST",
      headers: withIdentity({ "Content-Type": "application/json" }),
      body: JSON.stringify({ type, ...data, pl: PAGE_LOAD }),
      keepalive: true, // survive a nav/unload that fires right after the event
    }).catch(() => {});
  } catch {
    /* telemetry must never break the app */
  }
}

// POSTs that aren't deliberate user actions: the telemetry sink itself, the keepalive, and
// the hover-prefetch (fires on mouseover, not on an action). Everything else POSTed is an action.
const SKIP_TRACK = new Set(["/track", "/heartbeat", "/prepare"]);
let installed = false;

// WHAT the action was aimed at, lifted from the request body every mutating POST already sends.
// Without it the log records that a /contract 404'd but not on which branch, so reading back a
// past session means inferring the target from surrounding timestamps — an hour of detour on the
// frozen-model hunt (2026-07-21). Truncated: a target is a name, never a payload.
const targetOf = (body: BodyInit | null | undefined): string => {
  if (typeof body !== "string") return "";
  try {
    const b = JSON.parse(body) as Record<string, unknown>;
    const t = b.branch ?? b.project ?? b.name;
    return typeof t === "string" ? t.slice(0, 120) : "";
  } catch {
    return "";
  }
};

// Instrument the ONE layer every request passes through, so EVERY action POST is tracked —
// with its outcome and latency (ms) — no matter which component fires it, present or future.
// This is what makes "are all actions tracked?" answerable with yes, by construction.
// Outcome is `ok` + `err`, not just status: ~30 server paths refuse with 200 {ok:false}, which a
// status alone logged as success. The server names the refusal in X-Stack-Refused (a short
// class, never the message), so this reads a header instead of cloning every body.
export function installFetchTracking(): void {
  if (installed || !canMutate) return;
  installed = true;
  window.fetch = (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    let path = "";
    let isPost = false;
    let own = false;
    try {
      const method = (init?.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase();
      isPost = method === "POST";
      const raw = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      const url = new URL(raw, location.origin);
      path = url.pathname;
      own = sameOrigin(url);
    } catch {
      /* unparseable target — pass through untracked */
    }
    const t0 = performance.now();
    const rid = `${PAGE_LOAD}-${++ridSeq}`;
    const p = own
      ? realFetch(input, { ...init, headers: withIdentity(init?.headers ?? (input instanceof Request ? input.headers : undefined), rid) })
      : realFetch(input, init);
    if (isPost && own && !SKIP_TRACK.has(path)) {
      timedPost(path, rid, p);
      const on = targetOf(init?.body);
      const done = (status: number, refused: string | null) =>
        track("action", {
          url: path,
          ...(on ? { on } : {}),
          status,
          ok: !refused && status >= 200 && status < 400,
          ...(refused ? { err: refused } : status >= 400 || status === 0 ? { err: status ? `http-${status}` : "network" } : {}),
          ms: Math.round(performance.now() - t0),
          rid,
        });
      p.then((r) => done(r.status, r.headers.get("X-Stack-Refused")), () => done(0, null));
    }
    return p;
  };
}

let uiInstalled = false;

const SEMANTIC = "[data-track], button, [role=button], a[href]";

// Solid delegates onClick: the handler lives on the element as `$$click`. That is how a bare
// `<g onClick>` (every ForestMap node — 71% of forest→node navigation went unlogged) or a
// `div onClick` is found without annotating it.
const hasClickHandler = (el: Element) => typeof (el as unknown as Record<string, unknown>).$$click === "function";

// The nearest thing that was clicked AS a control: a semantic one, or an element with a handler.
export function clickedControl(target: Element | null): Element | null {
  for (let el = target; el && el !== document.documentElement; el = el.parentElement) {
    if (el.matches(SEMANTIC) || hasClickHandler(el)) return el;
  }
  return null;
}

// tag.first-class — a structural name for an unlabelled control ("g.fm-node"), stable across copy edits.
const shapeOf = (el: Element) => {
  const cls = (el.getAttribute("class") || "").trim().split(/\s+/)[0];
  return el.tagName.toLowerCase() + (cls ? "." + cls : "");
};

// Durable ids for the unlabelled controls that matter most, keyed by shape so the components
// that draw them carry no tracking markup: the forest map's node, PR badge and ghost pills.
const SHAPE_IDS: Record<string, string> = {
  "g.fm-node": "map.node",
  "text.fm-pr": "map.pr",
  "g.fm-ghost-pill": "map.ghost-pill",
};

// The client-interaction layer the fetch seam can't see: clicks (even ones that never hit the
// network, like the DIFF-VS toggles) and keyboard shortcuts (so an accidentally-hit or
// never-used key shows up by frequency). One delegated listener each — total coverage, no
// per-control annotation required.
//
// Naming convention: `data-track="<area>.<control>"` (e.g. "node.push", "map.node") is the
// control's durable id and lands in `track`; `control` stays the human label (aria-label, title,
// else text) as before, so history before data-track keeps classifying. Tooltips double as labels,
// so a copy edit splits one control into many classes — anything read by frequency wants an id.
export function installUiTracking(): void {
  if (uiInstalled || !canMutate) return;
  uiInstalled = true;

  document.addEventListener(
    "click",
    (e) => {
      const el = clickedControl(e.target as Element | null);
      if (!el) return;
      const id = el.getAttribute("data-track") || SHAPE_IDS[shapeOf(el)] || "";
      const labelled = el.getAttribute("aria-label") || el.getAttribute("title");
      const text = (el.textContent || "").trim().replace(/\s+/g, " ").slice(0, 40);
      if (el.matches(SEMANTIC)) {
        const control = labelled || text || id;
        if (control) track("ui", { control, ...(id ? { track: id } : {}) });
      } else {
        // a handler on a non-control element: its text is live data (a branch name, a count),
        // so the stable name is its shape; the text rides along as the target
        track("ui", { control: labelled || shapeOf(el), el: shapeOf(el), ...(id ? { track: id } : {}), ...(text ? { text } : {}) });
      }
    },
    { capture: true },
  );

  document.addEventListener(
    "keydown",
    (e) => {
      const t = e.target as HTMLElement | null;
      if (t && (t.isContentEditable || t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT")) {
        return; // typing into a field, not firing a shortcut
      }
      if (e.key === "Meta" || e.key === "Control" || e.key === "Alt" || e.key === "Shift") {
        return; // a modifier ALONE isn't a shortcut — bare Cmd was 627 "cmd+Meta" rows, half the key stream
      }
      const mods = e.metaKey || e.ctrlKey || e.altKey;
      if (e.key.length !== 1 && !mods) return; // bare Arrow/Enter/Escape/Tab = navigation noise, skip
      const prefix = [e.metaKey && "cmd", e.ctrlKey && "ctrl", e.altKey && "alt", e.shiftKey && "shift"].filter(Boolean);
      track("key", { key: [...prefix, e.key.length === 1 ? e.key.toLowerCase() : e.key].join("+") });
    },
    { capture: true },
  );
}

// ── the v1 baseline: how long v1 FEELS, measured generically so v2 has a number to beat ──────
// For every keyboard shortcut and control click: input → the frame that paints the first DOM
// change (feedbackMs) and input → the end of any mutating POST it fired (settledMs). For every
// route change: navigation → the last paint before the page settles (paintMs; see measureNav).
// Schema-2 `timing` events, keyed by data-track id / `key:<k>` / label and by route kind — the
// v2 registry names the v1 ids each command replaces, so the dashboard pairs them.
const CONFIG_POSTS = new Set(["/project-state", "/focus", "/purpose", "/ticket", "/notes", "/trunk", "/frozen-origin",
  "/plan-template", "/drop-project", "/outbox-hold", "/outbox-title", "/outbox-label"]);
const INPUT_WINDOW = 300;
const SETTLE_CAP = 30_000;

interface Input {
  id: string;
  via: "key" | "click";
  t0: number;
  posts: { path: string; rid: string; done: Promise<{ end: number; status: number; refused: string | null }> }[];
}
let lastInput: Input | null = null;

function timedPost(path: string, rid: string, p: Promise<Response>): void {
  const inp = lastInput;
  if (!inp || performance.now() - inp.t0 > INPUT_WINDOW) return;
  inp.posts.push({
    path,
    rid,
    done: p.then(
      (r) => ({ end: performance.now(), status: r.status, refused: r.headers.get("X-Stack-Refused") }),
      () => ({ end: performance.now(), status: 0, refused: null }),
    ),
  });
}

function firstPaint(t0: number): Promise<number | null> {
  return new Promise((resolve) => {
    const obs = new MutationObserver(() => {
      obs.disconnect();
      clearTimeout(t);
      requestAnimationFrame(() => resolve(Math.round((performance.now() - t0) * 10) / 10));
    });
    obs.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
    const t = window.setTimeout(() => {
      obs.disconnect();
      resolve(null);
    }, 1000);
  });
}

const timing = (data: Record<string, unknown>) => track("timing", { schema: 2, app: "v1", ...data });

function onInput(id: string, via: "key" | "click", t0: number): void {
  const inp: Input = { id, via, t0, posts: [] };
  lastInput = inp;
  const feedback = firstPaint(t0);
  window.setTimeout(async () => {
    const feedbackMs = await feedback;
    if (feedbackMs == null && !inp.posts.length) return; // nothing happened: a stray key, not a command
    const cap = new Promise<null>((r) => window.setTimeout(() => r(null), SETTLE_CAP));
    const done = await Promise.race([Promise.all(inp.posts.map((x) => x.done)), cap]);
    const last = done?.length ? done.reduce((a, b) => (a.end > b.end ? a : b)) : null;
    const bad = done?.find((d) => d.refused || d.status >= 400 || d.status === 0);
    const post = inp.posts[0]?.path;
    timing({
      kind: "input",
      id,
      via,
      budget: post ? (CONFIG_POSTS.has(post) ? "config-write" : "git-write") : "local",
      feedbackMs,
      settledMs: last ? Math.round((last.end - t0) * 10) / 10 : null,
      outcome: inp.posts.length && !done ? "failed" : !bad ? "ok" : bad.refused || (bad.status && bad.status < 500) ? "refused" : "failed",
      ...(bad ? { err: bad.refused || (bad.status ? `http-${bad.status}` : "network") } : {}),
      ...(post ? { post, rid: inp.posts[0].rid } : {}),
    });
  }, INPUT_WINDOW);
}

function surfaceOf(pathname: string): string {
  const l = parseLocation(pathname, "");
  return l.kind === "forest" && l.node ? "node" : l.kind === "standalone" || l.kind === "review" ? "node" : l.kind;
}

// v1 assembles a page from several requests, each painting as it lands, so its "content" is the
// last DOM change before the page goes quiet for QUIET ms with no `.loading` placeholder left.
const QUIET = 300;

function measureNav(from: string, to: string, t0: number): void {
  let painted: number | null = null;
  const obs = new MutationObserver(() => requestAnimationFrame(() => (painted = performance.now())));
  obs.observe(document.body, { subtree: true, childList: true, characterData: true });
  const started = performance.now();
  const tick = () => {
    const now = performance.now();
    if (painted != null && now - painted >= QUIET && !document.querySelector(".loading")) {
      obs.disconnect();
      timing({ kind: "nav", from, to, paintMs: Math.round((painted - t0) * 10) / 10 });
    } else if (now - started > 15_000) {
      obs.disconnect();
      timing({ kind: "nav", from, to, paintMs: null });
    } else requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

let timingInstalled = false;

export function installTiming(): void {
  if (timingInstalled || !canMutate) return;
  timingInstalled = true;
  document.addEventListener(
    "keydown",
    (e) => {
      const t = e.target as HTMLElement | null;
      if (t && (t.isContentEditable || t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT")) return;
      if (e.key.length !== 1 || e.metaKey || e.ctrlKey || e.altKey) return;
      onInput(`key:${e.key.toLowerCase()}`, "key", e.timeStamp);
    },
    { capture: true },
  );
  document.addEventListener(
    "click",
    (e) => {
      const el = clickedControl(e.target as Element | null);
      if (!el) return;
      const label = (el.getAttribute("aria-label") || el.getAttribute("title") || (el.textContent || "").trim()).replace(/\s+/g, " ").slice(0, 32);
      const id = el.getAttribute("data-track") || SHAPE_IDS[shapeOf(el)] || (label ? `click:${label}` : shapeOf(el));
      onInput(id, "click", e.timeStamp);
    },
    { capture: true },
  );
  let path = location.pathname;
  measureNav("", surfaceOf(path), 0);
  const moved = () => {
    if (location.pathname === path) return;
    const from = surfaceOf(path);
    path = location.pathname;
    const recent = lastInput && performance.now() - lastInput.t0 < 500 ? lastInput.t0 : performance.now();
    measureNav(from, surfaceOf(path), recent);
  };
  const push = history.pushState.bind(history);
  history.pushState = (...args: Parameters<History["pushState"]>) => {
    push(...args);
    moved();
  };
  window.addEventListener("popstate", moved);
}
