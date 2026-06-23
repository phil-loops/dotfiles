# HEADS-UP: viewer → Solid migration (+ JobStatus query rename) — 2026-06-17

Two in-flight changes other sessions should know before touching the viewer or the
goal-metrics-page-job stack. (Dropped as a file because claude-say couldn't reach the
live sessions — several were mid-exit / at 100% context.)

## 1. The blessing viewer is being rebuilt in Solid

- New app: `scripts/viewer-solid/` — **Solid + Vite + @tanstack/solid-query**. `npm run dev`
  serves it on **:5174**; Vite **proxies the EXISTING Python JSON/SSE API on :62333**
  (`/model`, `/node`, `/projects`, `/myprs`, `/bless`, `/events`, …). **Zero backend
  changes** — the Python server is untouched and stays the API.
- The **vanilla viewer** (`scripts/viewer/` + `stack-review-server.py`) still runs and is
  the live one for now, but it is **being superseded**. Don't invest heavily in it, and
  **don't build a parallel picker/viewer** — if you're in `srv/picker.py` or similar,
  coordinate first (the Solid app already covers the home + node-detail).
- Built so far: **home** (open PRs grouped by forest + forests with behind-state +
  check-origin), **node-detail** (forest spine + manuscript diffs + per-file bless + a
  foil-on-bless moment), **j/k** keyboard node-walk, **parent/main/last-blessed** diff-base
  toggle. solid-query replaces the hand-rolled NODEPATCH cache / SWR / timeout-retry; SSE
  invalidation replaces the manual selective re-render.

### Design principle (applies to BOTH viewers): earn the gold — NO bless-all
Gold = the *blessed* state, earned **per file by actually reading the diff**. A bless-all
marks work reviewed without reviewing it, which makes the gold a lie. The vanilla's "bless
all remaining" button was removed (`de17f37`). Do not add bulk-bless anywhere.

## 2. JobStatus goals-result query fns were renamed (goal-metrics-page-job stack)

In `queries/job-status.ts`:
- `initJobResult` → **`initGoalsJobResult`**
- `mergeAttachmentResult` → **`setAttachmentResult`** — now writes via a direct
  `jsonb_set(result, ARRAY['perAttachment', attachmentId], stats, true)` path (no
  perAttachment rebuild); input field `entry` → **`stats`**. Relies on init having stamped
  the envelope first (documented contract).

Landed on `job-status/result-merge`, cascaded up through `metrics-job → … →
remove-dead-endpoints`; `queries/job-status.test.ts` + `jobs/goal-source-metrics.{ts,test.ts}`
updated to match. **If you're editing those files, rebase onto the new tips or use the new
names** so you don't collide.
