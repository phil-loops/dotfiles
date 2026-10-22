// Where each branch stands on its way to main, and what the clock says about pushing now — pure,
// so node --test pins the rules. The facts are the outbox's (srv/outbox.py), derived from the store.
import type { Branch, Pr } from "./types";

export type Ship = "local" | "green" | "pushed" | "review" | "approved" | "landed";

export const SHIP: Record<Ship, { glyph: string; word: string }> = {
  local: { glyph: "○", word: "local" },
  green: { glyph: "●", word: "green" },
  pushed: { glyph: "↑", word: "pushed" },
  review: { glyph: "◇", word: "in review" },
  approved: { glyph: "◆", word: "approved" },
  landed: { glyph: "✓", word: "landed" },
};

export interface Waiting {
  kind: "parent" | "draft" | "conflicts" | "ci" | "behind" | "checks" | "merge";
  label: string;
}

/** The branch's action on ↵ — one per state. */
export type Action = "push" | "pr" | "open" | null;

export interface Stand {
  ship: Ship;
  action: Action;
  /** an approved PR: what it still waits on, first thing first */
  waiting: Waiting[];
  /** you can act on it right now (the ready filter) */
  ready: boolean;
  /** held for the morning and not yet due */
  held: boolean;
}

export function shipOf(b: Branch, pr: Pr | undefined): Ship {
  if (pr?.state === "MERGED") return "landed";
  if (pr?.state === "OPEN") return pr.review === "APPROVED" ? "approved" : "review";
  if (b.pushed === "synced" && b.commits > 0) return "pushed";
  return b.gates === "green" && b.commits > 0 ? "green" : "local";
}

const settled = (s: Ship | undefined) => s === undefined || s === "landed";

export function waitingOn(pr: Pr, parent: { ship: Ship; pr?: Pr; name: string } | undefined): Waiting[] {
  const out: Waiting[] = [];
  if (parent && !settled(parent.ship)) {
    out.push({ kind: "parent", label: parent.pr ? `parent #${parent.pr.number} to merge` : `${leaf(parent.name)} to open its PR` });
  }
  if (pr.draft) out.push({ kind: "draft", label: "being a draft" });
  const ms = (pr.mergeState ?? "").toUpperCase();
  if (pr.mergeable === "CONFLICTING" || ms === "DIRTY") out.push({ kind: "conflicts", label: "its conflicts" });
  else if (ms === "UNSTABLE") out.push({ kind: "ci", label: "failing CI" });
  else if (ms === "BEHIND") out.push({ kind: "behind", label: "catching up with its base" });
  else if (ms === "BLOCKED" && !out.length) out.push({ kind: "checks", label: "required checks" });
  if (!out.length) out.push({ kind: "merge", label: "you — merge it" });
  return out;
}

export const leaf = (name: string) => name.split("/").pop() ?? name;

/** Everything the page shows about one branch, given its parent's standing (merge order makes the
 *  parent's available first). `now` decides whether a hold has come due. */
export function stand(
  b: Branch,
  pr: Pr | undefined,
  parent: { ship: Ship; pr?: Pr; name: string } | undefined,
  now: number,
): Stand {
  const ship = shipOf(b, pr);
  const held = !!b.holdUntil && !pr && Date.parse(b.holdUntil) > now;
  const waiting = ship === "approved" && pr ? waitingOn(pr, parent) : [];
  const parentOnOrigin = !parent || (parent.ship !== "local" && parent.ship !== "green");
  let ready = false;
  if (ship === "green") ready = parentOnOrigin && !held;
  else if (ship === "pushed") ready = !held;
  else if (ship === "approved") ready = waiting[0]?.kind !== "parent";
  const action: Action = ship === "green" ? "push" : ship === "pushed" || ship === "review" || ship === "approved" ? "pr" : "open";
  return { ship, action, waiting, ready, held };
}

/** The PR's base for a compare link: the parent's branch while it's unlanded, else trunk. */
export const baseFor = (b: Branch, parent: { ship: Ship; name: string } | undefined, trunk: string) =>
  parent && !settled(parent.ship) ? parent.name : trunk;

/** A forest is closed once every branch in it has landed. */
export const isClosed = (ships: Ship[]) => ships.length > 0 && ships.every((s) => s === "landed");

// ── the clock against the 15:00 PT cliff (srv/outbox.py WINDOW, measured over 2026's PRs) ──

export const WINDOW = { cliffHourPT: 15, slowH: 18.8, fastH: 3.2, morningHourPT: 9 };
const PT = "America/Los_Angeles";

interface PtParts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  weekday: number;
}

function ptParts(ms: number): PtParts {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: PT, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", weekday: "short",
  }).formatToParts(new Date(ms));
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return {
    year: +get("year"), month: +get("month"), day: +get("day"), hour: +get("hour") % 24, minute: +get("minute"),
    weekday: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(get("weekday")),
  };
}

function ptToMs(y: number, mo: number, d: number, h: number, near: number): number {
  const p = ptParts(near);
  const offset = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute) - Math.floor(near / 60_000) * 60_000;
  return Date.UTC(y, mo - 1, d, h, 0) - offset;
}

/** The next weekday morning at `hour` PT — today's if it's still ahead. */
export function nextMorning(ms: number, hour = WINDOW.morningHourPT): number {
  for (let i = 0; i < 8; i++) {
    const p = ptParts(ms + i * 86_400_000);
    if (p.weekday === 0 || p.weekday === 6) continue;
    const at = ptToMs(p.year, p.month, p.day, hour, ms);
    if (at > ms) return at;
  }
  return ms + 86_400_000;
}

export type Phase = "open" | "closing" | "late" | "weekend";

export function phaseAt(ms: number): { phase: Phase; minutesToCliff: number } {
  const p = ptParts(ms);
  const minutesToCliff = Math.round((WINDOW.cliffHourPT - (p.hour + p.minute / 60)) * 60);
  if (p.weekday === 0 || p.weekday === 6) return { phase: "weekend", minutesToCliff };
  if (minutesToCliff <= 0) return { phase: "late", minutesToCliff };
  return { phase: minutesToCliff <= 60 ? "closing" : "open", minutesToCliff };
}

export const fmtMorning = (ms: number) =>
  new Intl.DateTimeFormat("en-US", { timeZone: PT, weekday: "short", hour: "numeric" }).format(new Date(ms)).replace(" AM", "am").replace(" PM", "pm");

/** The push window's one line, or "" while the window is comfortably open. */
export function windowLine(ms: number): string {
  const { phase, minutesToCliff } = phaseAt(ms);
  const slow = Math.round(WINDOW.slowH);
  switch (phase) {
    case "open":
      return "";
    case "closing":
      return `${minutesToCliff}m to 3pm — a PR opened after it takes ~${slow}h to merge`;
    case "late":
      return `past 3pm — a PR opened now takes ~${slow}h to merge, ~${Math.round(WINDOW.fastH)}h from ${fmtMorning(nextMorning(ms))}`;
    case "weekend":
      return `the weekend — nobody reviews until ${fmtMorning(nextMorning(ms))}`;
  }
}
