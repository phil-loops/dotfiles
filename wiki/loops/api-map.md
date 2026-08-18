---
title: API directions & hard lines
section: API foundation spikes
order: 50
project: metrics-api
ask: lib/rest-api/define-route.ts
lede: Every direction the public API is considering, and the lines none of them may cross.
---

## Hard lines (drawn; a proposal that crosses one is wrong, not novel)

1. **The cardinality line.** Message-cardinality questions (thousands of rows) answer synchronously; contact-cardinality questions (millions) are async-resource-only. No query param may silently move an endpoint across the line — that's how you get one URL with two cost classes and a silent 50k fallback.
2. **One canonical URL per metric object.** Wrong-noun access gets a coded 400 naming the right URL. Never two addresses for one number.
3. **All-time counters are all-time.** No date-window params on aggregates (they'd misattribute continuously-sending messages). Date filters on lists select rows, never window numbers. Partial aggregates are never served — complete-or-absent, progress is not a number.
4. **Counts, not rows**, for contact-flavored data on any sync surface.
5. **PII by reference.** Async results durably store the question and the aggregates; matching contacts are read live at page time, never copied. Explicit exports (CSV artifacts) are the only copy path.
6. **Additive forever, no v2.** New capability = new nouns/fields within v1 (the transactional-emails precedent). Fields are never removed or renamed; deprecations ride until separately documented.
7. **Public bodies name their fields** — explicit selection, never a spread of a model result; enforced by drops-extra-fields tests. Peer-source shape: email metrics under `email:`, future sources (goals) as siblings.
8. **Codes forward-only.** New endpoints mint codes as authored (literals allowed pre-registry-merge, absorbed after); no retro sweeps without a trigger. Named helpers per semantic case; `err(status, message, opts?)` is the escape hatch; never two positional optionals.
9. **Pagination is for bounded enumerations only.** Summaries and single objects never paginate; unbounded row sets become async snapshots (then page stably) or artifacts.
10. **Filters travel in POST bodies.** The filtered question becomes a created resource — no URL-encoded filter trees, no waiting on the QUERY method.
11. **UTC explicit** in every metrics body; the field exists before it's configurable.
12. **Spec follows behavior.** Undocumented-additive is the soft launch; OpenAPI documentation is the commitment ceremony.

## Directions in play, by state

**Proposed with stakeholder demand (Adam, Jul 7 — support-driven):**
- `GET /v1/campaigns/{id}/recipients` — paginated contact interactions per message; FK-bounded, sync-safe.
- `GET /v1/contacts/{id}/email-activity` — a contact's recent emails + what they did with them; bounded by contact. *Verify an `Email(contactId, createdAt)` index exists before promising cheap.*

**Proposed, awaiting go:**
- `GET /v1/metrics/messages` — paginated union of canonical metric objects (type/workflowId/date filters; transactional rows are the rolled object, never versions).
- `GET /v1/workflows/{id}/metrics` — one rolled summary; per-node breakdown via the list's `workflowId` filter.

**Open rulings:**
- Transactional body: strip opens/clicks/unsubscribes (July notes say yes — tracking unreliable; built route currently exposes them)?
- Workflow node addressing: `/email-messages/{id}/metrics` (built, canonical) vs `/workflows/{id}/nodes/{id}/metrics` (graph-scoped)?
- `perPage` min 10→1 (built, parkable) — ship or park?
- `totalResults` when filters arrive: counting a filtered list costs as much as the page — optional/lazy/estimated, or count rides async?
- Multi-value filter params: serialization is a deliberate compile error until someone decides the wire format.

**Parked with triggers:**
- `POST/GET /v1/metric-reports` (+`/rows`) and `POST/GET /v1/contact-queries` — triggers: a customer asks for filtered/cross-message metrics or contact enumeration; the storage decision lands; list-iteration pain.
- Goals metrics — computed-on-demand = async class; never rolled into email metrics (no TableFilter drilldown); natural fit = a report type when reports un-park; attachment-ids-only is the acknowledged can-kick.
- Error-code sweep, OpenAPI Error-schema consolidation, code-primary/required flip (sweep's exit criterion), workflow-adapter branch (whole branch parked; one-line serialize-existing-code alternative recorded).

**Storage decisions (the only clocks that matter):**
- Daily send rollup — *backfillable* from `Email.createdAt`, so decide when the chart is wanted, not before.
- Open/click timestamps — *irreversible* (counters only; 3-day buffer purges); the deliberate product call that gates engagement time-series. Two decisions, priced separately.

**Dropped (not deferred):** team-wide `GET /v1/metrics` rollup; per-version transactional metrics; `Team.timezone` column; prefactoring anything whose feature lacks a trigger.
