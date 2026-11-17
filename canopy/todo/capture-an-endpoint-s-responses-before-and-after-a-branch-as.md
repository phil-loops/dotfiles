+++
title = "Capture an endpoint's responses before and after a branch, as evidence"
kind = "build"
state = "doing"
owner = "8372863d"
area = "review"
size = "M"
why = "evidence only knows screenshots; endpoint work needs the same pinned before/after, frozen prediction and Phil's verdict over request/response captures"
links = ["canopy/todo/decide-the-staging-probe-s-open-calls-where-the-url-and-key.md"]
created = "2026-11-16"
updated = "2026-11-16"
+++

Evidence's kernel — one pinned subject, a prediction frozen before capture, before/after compared, Phil judges — with requests in place of screenshots. Local only: both sides served by loops-preview on the pinned evidence checkouts, signed in as the dev user, exactly like app recipes. The staging probe (linked) later reuses the same comparison with staging as a side.

## Recipe (`"kind": "api"`)
```json
{"kind": "api", "title": "…",
 "requests": [{"id": "team-limits", "method": "GET", "path": "/api/trpc/admin.teamLimits?input=…",
               "file": "trpc/routers/admin.ts", "anchor": "teamLimits", "mask": ["$..createdAt", "$..id"]}],
 "variants": [{"id": "dev-user"}]}
```
- **Reads only (v1).** `method` must be GET (tRPC queries are GETs). A write mutates the shared dev DB the next capture reads — refused until a per-run database exists.
- **mask**: JSON paths removed before comparing; nothing is masked by default.
- **file + anchor**: coverage, measured as for views — the request covers `file` only if `anchor` occurs in the after-side source.

## Capture (`evidence-api-capture.mjs`, one attempt)
Playwright's request context (no browser): sign in through the email callback with the engine's one-use token, fire each request, record status, content-type and the body. JSON bodies are canonicalized (sorted keys) after masking; the artifact is that canonical text, stored by sha in the existing blob store. Non-JSON bodies are stored raw.

## Admission and claim
Claim class `live` (shared dev DB), same as app recipes: two attempts in one run must match byte for byte after masks, else "not repeatable: <paths> differ — mask them". Same lease, served-HEAD check, dropped builds, pinned basis, nonce.

## Prediction and finding
`same` | `changes` | `{"paths": ["$.result.data.limit"]}` — only those paths may change. A finding lists the JSON paths added, removed and changed (before → after, truncated), plus status change. Departure: `same` with any difference; `changes` with none; `paths` with a status change or a difference outside the declared paths.

## Canopy
The card shows per request: status before → after, then the path diff (path, before, after). The departure/unchanged counts, coverage and gaps lines, accept/reject, current/eligible/judge_current, auto-refresh — unchanged. `shown` = every diff loaded (no images).

## Slices
1. Engine: api recipe, capture script, masking + canonical blobs, path diff + findings, admission; tests on a fake capture; `evidence run` end to end against a local preview (needs OrbStack up).
2. Canopy: a request-diff view in place of the image grid for `kind: api`.
3. Coverage for api files (route/router file + anchor), joined with the UI coverage set.
Later: writes against a throwaway DB; staging as a side (probe items).

## Next steps
1. End-to-end: start OrbStack, write a recipe + request for a branch that changes a tRPC query (e.g. an admin query), `evidence run <branch>` — first run will say which paths aren't repeatable; mask them by name.
2. Look at the card in canopy (the request list hasn't been seen on screen yet).
3. Later: writes against a per-run database; staging as a side (probe items).
