import { canMutate } from "./provider";

// The original fetch, captured before installFetchTracking() wraps window.fetch — so the
// telemetry POST below never re-enters the wrapper (and keeps working if other code wraps fetch).
const realFetch = window.fetch.bind(window);

// Fire-and-forget local usage telemetry → POST /track (the server appends one JSONL line
// to .git/stack-usage.jsonl). Single-user, never leaves the machine, never committed.
// Live mode only — a static snapshot has no server to post to. NEVER awaited and NEVER
// allowed to throw into the UI: a dropped event is fine, a broken action is not.
export function track(type: string, data: Record<string, unknown> = {}): void {
  if (!canMutate) return;
  try {
    void realFetch("/track", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ type, ...data }),
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
// with its outcome (status) and latency (ms) — no matter which component fires it, present or
// future. This is what makes "are all actions tracked?" answerable with yes, by construction.
export function installFetchTracking(): void {
  if (installed || !canMutate) return;
  installed = true;
  window.fetch = (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    let path = "";
    let isPost = false;
    try {
      const method = (init?.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase();
      isPost = method === "POST";
      const raw = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      path = new URL(raw, location.origin).pathname;
    } catch {
      /* unparseable target — pass through untracked */
    }
    const t0 = performance.now();
    const p = realFetch(input, init);
    if (isPost && path && !SKIP_TRACK.has(path)) {
      const on = targetOf(init?.body);
      const done = (status: number) =>
        track("action", { url: path, ...(on ? { on } : {}), status, ms: Math.round(performance.now() - t0) });
      p.then((r) => done(r.status), () => done(0));
    }
    return p;
  };
}

let uiInstalled = false;

// The client-interaction layer the fetch seam can't see: button clicks (even ones that never
// hit the network, like the DIFF-VS toggles) and keyboard shortcuts (so an accidentally-hit or
// never-used key shows up by frequency). One delegated listener each — total coverage, no
// per-control annotation. A control names itself via data-track, else its aria-label/title/text.
export function installUiTracking(): void {
  if (uiInstalled || !canMutate) return;
  uiInstalled = true;

  document.addEventListener(
    "click",
    (e) => {
      const el = (e.target as Element | null)?.closest?.("[data-track], button, [role=button], a[href]");
      if (!el) return;
      const label =
        el.getAttribute("data-track") ||
        el.getAttribute("aria-label") ||
        el.getAttribute("title") ||
        (el.textContent || "").trim().slice(0, 40);
      if (label) track("ui", { control: label });
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
