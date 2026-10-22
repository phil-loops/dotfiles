// Latency budgets by class (wiki canopy-v2-measure); feedback is one 60 Hz frame. A command declares its class in the
// registry; the dashboard reads the table from the registry event, so this is the one source.
export type BudgetClass = "local" | "config-write" | "git-write" | "slow-io";

export const BUDGETS: Record<BudgetClass, { feedbackMs: number; settledMs: number | null }> = {
  local: { feedbackMs: 16.7, settledMs: null },
  "config-write": { feedbackMs: 16.7, settledMs: 300 },
  "git-write": { feedbackMs: 16.7, settledMs: 3000 },
  "slow-io": { feedbackMs: 16.7, settledMs: 15000 },
};

export const PAINT_MS = 100;
