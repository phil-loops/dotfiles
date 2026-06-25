import { canMutate } from "./provider";

// Fire-and-forget local usage telemetry → POST /track (the server appends one JSONL line
// to .git/stack-usage.jsonl). Single-user, never leaves the machine, never committed.
// Live mode only — a static snapshot has no server to post to. NEVER awaited and NEVER
// allowed to throw into the UI: a dropped event is fine, a broken action is not.
export function track(type: string, data: Record<string, unknown> = {}): void {
  if (!canMutate) return;
  try {
    void fetch("/track", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ type, ...data }),
      keepalive: true, // survive a nav/unload that fires right after the event
    }).catch(() => {});
  } catch {
    /* telemetry must never break the app */
  }
}
