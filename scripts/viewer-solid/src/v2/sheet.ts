// What the `?` sheet shows: the current surface's scopes, the ones live under the cursor first,
// then everywhere. Other surfaces' keys are left out — they don't work here.
export const SURFACE_SCOPES: Record<string, string[]> = {
  forests: ["branch", "project", "row", "forests"],
  review: ["pending", "thread", "line", "review"],
  dashboard: ["dashboard"],
};

export const SCOPE_TITLES: Record<string, string> = {
  global: "Everywhere",
  forests: "On Forests",
  row: "On a forest or branch",
  project: "On a forest",
  branch: "On a branch",
  dashboard: "On the dashboard",
  review: "Reviewing a branch",
  line: "On a diff line",
  thread: "On a conversation",
  pending: "On a pending comment",
};

/** Sections in order; `live` marks the scopes under the cursor (narrowest first, from liveScopes). */
export function sheetSections(surface: string, live: string[]): { scope: string; live: boolean }[] {
  const mine = SURFACE_SCOPES[surface] ?? [];
  const now = live.filter((s) => mine.includes(s));
  const rest = mine.filter((s) => !now.includes(s));
  return [...now.map((scope) => ({ scope, live: true })), ...rest.map((scope) => ({ scope, live: false })), { scope: "global", live: true }];
}
