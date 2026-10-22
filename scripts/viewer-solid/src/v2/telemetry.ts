// The telemetry sink and its measuring tools. Only the three choke points — the runner (every
// command), the router (every navigation) and sync (every server round trip) — import this;
// structure.test.ts fails the build if anything else does. Events are schema 2 (documented in
// scripts/viewer-usage-report), batched to POST /track, and flushed by sendBeacon when the tab
// hides. High-frequency signals (long tasks, layout shift, sync traffic) are aggregated into one
// `page` event per page load instead of one event each.

export const SCHEMA = 2;
export const APP = "v2";
export const PAGE_LOAD = Math.random().toString(36).slice(2, 8);
export const ACTOR = navigator.webdriver ? "headless" : "browser";

type Event = Record<string, unknown> & { type: string };

const queue: Event[] = [];
let timer: number | undefined;
const FLUSH_MS = 3000;

export function emit(ev: Event): void {
  queue.push({ schema: SCHEMA, app: APP, pl: PAGE_LOAD, ...ev });
  timer ??= window.setTimeout(() => flush(false), FLUSH_MS);
}

function flush(beacon: boolean): void {
  clearTimeout(timer);
  timer = undefined;
  if (!queue.length) return;
  const body = JSON.stringify({ type: "batch", events: queue.splice(0) });
  try {
    if (beacon && navigator.sendBeacon) {
      navigator.sendBeacon("/track", new Blob([body], { type: "application/json" }));
    } else {
      void fetch("/track", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Stack-Actor": ACTOR },
        body,
        keepalive: true,
      }).catch(() => {});
    }
  } catch {
    /* a dropped batch is fine; a broken page is not */
  }
}

// ── per-page-load aggregates ───────────────────────────────────────────────

const page = {
  longtasks: 0,
  longtaskMs: 0,
  longtaskMax: 0,
  cls: 0,
  counters: {} as Record<string, number>,
  timings: {} as Record<string, number[]>,
};

/** Count a high-frequency fact (a patch, a resync) into this page load's aggregate. */
export function count(name: string, ms?: number): void {
  page.counters[name] = (page.counters[name] ?? 0) + 1;
  if (ms != null) (page.timings[name] ??= []).push(Math.round(ms));
}

function flushPage(): void {
  const timings = Object.fromEntries(
    Object.entries(page.timings).map(([k, v]) => {
      const s = [...v].sort((a, b) => a - b);
      return [k, { n: s.length, p50: s[Math.floor(s.length / 2)], max: s[s.length - 1] }];
    }),
  );
  const any = page.longtasks || page.cls || Object.keys(page.counters).length;
  if (any) {
    emit({
      type: "page",
      route: location.pathname,
      longtasks: { n: page.longtasks, totalMs: Math.round(page.longtaskMs), maxMs: Math.round(page.longtaskMax) },
      cls: Math.round(page.cls * 1000) / 1000,
      counters: { ...page.counters },
      timings,
    });
  }
  Object.assign(page, { longtasks: 0, longtaskMs: 0, longtaskMax: 0, cls: 0, counters: {}, timings: {} });
  flush(true);
}

export function installPageTelemetry(): void {
  const observe = (type: string, fn: (e: PerformanceEntry) => void) => {
    try {
      new PerformanceObserver((list) => list.getEntries().forEach(fn)).observe({ type, buffered: true });
    } catch {
      /* entry type unsupported */
    }
  };
  observe("longtask", (e) => {
    page.longtasks++;
    page.longtaskMs += e.duration;
    page.longtaskMax = Math.max(page.longtaskMax, e.duration);
  });
  observe("layout-shift", (e) => {
    const s = e as PerformanceEntry & { value: number; hadRecentInput: boolean };
    if (!s.hadRecentInput) page.cls += s.value;
  });
  document.addEventListener("visibilitychange", () => document.visibilityState === "hidden" && flushPage());
  window.addEventListener("pagehide", flushPage);
}

// ── measuring ──────────────────────────────────────────────────────────────

/** ms from t0 to the frame that paints the next DOM change, or null if nothing changes within
 *  `wait` ms. Call BEFORE making the change: the observer has to be watching when it lands. */
export function nextPaint(t0: number, wait = 1000): Promise<number | null> {
  return new Promise((resolve) => {
    const done = (v: number | null) => {
      obs.disconnect();
      clearTimeout(t);
      resolve(v);
    };
    const obs = new MutationObserver(() => {
      obs.disconnect();
      requestAnimationFrame(() => done(Math.round((performance.now() - t0) * 10) / 10));
    });
    obs.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
    const t = window.setTimeout(() => done(null), wait);
  });
}

/** ms from t0 to the frame that paints `[data-paint=<surface>]` — a surface's meaningful content. */
export function contentPaint(surface: string, t0: number, wait = 15000): Promise<number | null> {
  const sel = `[data-paint="${surface}"]`;
  return new Promise((resolve) => {
    const settle = () => requestAnimationFrame(() => resolve(Math.round((performance.now() - t0) * 10) / 10));
    if (document.querySelector(sel)) return settle();
    const obs = new MutationObserver(() => {
      if (!document.querySelector(sel)) return;
      obs.disconnect();
      clearTimeout(t);
      settle();
    });
    obs.observe(document.body, { subtree: true, childList: true, attributes: true });
    const t = window.setTimeout(() => {
      obs.disconnect();
      resolve(null);
    }, wait);
  });
}
