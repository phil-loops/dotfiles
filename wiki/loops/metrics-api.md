---
title: Public metrics API
section: API foundation spikes
order: 40
project: metrics-api
ask: models/goals/campaign-goal-metrics.ts
lede: Two surfaces matched to two cost classes — counters read synchronously off the nouns that exist, report runs as an async resource for everything the counters can't answer.
---

Metrics storage has two economies. Per-message totals are denormalized counters on `EmailMessage`/`Transactional` — always current, one row read. Everything else — audience-filtered aggregates, cross-message rollups, recipient enumerations under a filter — is a scan over `Email` × `Contact` that can outlive any HTTP timeout (the internal engine caps at 50k rows and silently falls back). The API shape follows the storage shape.

**Surface 1 — counters as a sub-resource** (sync, cheap, the 90% question):

**One canonical URL per metric object (Phil, 2026-08-17), bare-resource bodies, `"timezone": "UTC"` explicit:**
- `/v1/campaigns/{id}/metrics` — one-shot; counters freeze after the send window, so they're honestly date-attributable.
- `/v1/email-messages/{id}/metrics` — **workflow/loop-owned messages ONLY** (their all-time accruing counters); campaign- and transactional-owned ids get a coded 400 pointing at the canonical URL (the workflow API's `UseEmailMessageApi` idiom).
- `/v1/transactional-emails/{id}/metrics` — ONLY the rolled-up `Transactional.n*` lifetime totals, never per-version: opens attribute to whichever version sent them, so version-level numbers slice one logical email's engagement across publish boundaries customers don't think in. Drafts are all-zeros rows; no URL.

No date-windowed aggregates anywhere in surface 1 — per-message counters are all-time accumulators; a windowed rollup would misattribute loop/transactional volume. Send-per-day time-series needs a daily rollup table (the cheap half of the storage decision); open/click time-series needs timestamped events (the expensive half). Built: `flag` → `queries` → `model` → `endpoints` (fan-in, requires flag) → `email-message-queries` → `email-message-metrics`. **No foundation dependency.**

**Surface 2 — the report run, a new top-level noun** (async, expensive, filterable):

`POST /v1/metric-reports {type, messageTypes, filter, timezone}` → `202 {id, status: "pending"}`; poll `GET /v1/metric-reports/{id}`. The query becomes a noun: progress is a field, failure is a status instead of a dropped connection, the result outlives the request (`JobStatus` underneath — durable JSON result, 7-day retention, the count-audience worker pattern: chunk, write partials, self-requeue). Stacks on the foundation and consumes all of it: idempotent create (`required: true` — a retried POST returns the same run, never a second scan; `insertJobIfAbsent`/`dedupeKey` are the pre-built get-or-create), `report.*` error codes at the 4xx sites, and the query-preserving pagination for results.

**Result shapes — pick by work profile, not payload type:**

1. **Bounded page → sync list.** Per-campaign recipient table = indexed FK slice per page; a plain cursor list, no job.
2. **Unbounded aggregate → report `summary`.** Complete-or-absent on the finished run — a partial count is a lie; while running, `progress`, never numbers.
3. **Computation-defined row set → report `rows` sub-resource.** Standard `{pagination, data}` cursor pages against a snapshot frozen at creation (`createdAt <= requestedAt` + the frozen filter), so page 40 tomorrow agrees with page 1 today.
4. **Bulk extraction → artifact.** S3 file + on-demand presigned URL (`AudienceDownloadRequest` is the in-repo precedent), for "all 2M rows".

**Decided constraints:** UTC-only v1, echoed in every response; time-series is a future report type gated on the one open product decision — timestamped open/click storage does not exist (`Email.vendorOpen` is a bare counter; the 3-day `EmailMetricAction` buffer purges) and only accrues from the day it ships. Report creation gets its own rate-limit bucket, stricter than the content-API bucket. The public report worker drops the 20s browser-watchdog self-cancel from the internal pattern (API clients poll slower; retention covers abandonment).

**Build order:** restack the dormant trio onto current main → surface-1 endpoint band (off main, now) → surface-2 forest stacked on `api-idempotency/route-option` + `api-pagination/next-page-query` once the foundation PRs land.
