---
title: Machine-readable error codes
section: API foundation spikes
order: 30
project: api-error-codes
ask: lib/rest-api/define-route.ts
lede: Every error is prose plus a status; 28 workflow codes die one line before the wire.
---

Nothing the public API emits is machine-distinguishable beyond the HTTP status. Seven concrete overloads: 401 means invalid-key OR content-gate-disabled OR workflow-gate-disabled (three body shapes); a workflow 409 is AlreadyPaused OR RevisionConflict; email-messages has three identical 409s; two unrelated 429s; catch-all 404 vs resource 404; and every multi-condition 400 within a route. Clients parse message prose or guess.

The workflow subsystem already built the answer and then dropped it: [28 typed codes](src:lib/workflow-operations/api-contract/workflow-api-error-codes.ts#WorkflowApiErrorCodes) travel through the model layer, and the [HTTP adapter](src:lib/workflow-operations/transport-support/http-request-helpers.ts#workflowApiResultToRouteResult) uses `errorCode` to pick a status, then forwards only the message. The fix there is a mapping table plus one argument.

**The standard: an additive `code` field** next to `message` — nothing existing breaks. Vocabulary is dot-namespaced snake_case (`auth.invalid_api_key`, `workflow.revision_conflict`), matching the repo's only public stable vocabulary (Svix event names) and the snake_case result codes models already use internally. Flat `as const` registry in `lib/rest-api/error-codes.ts`; the workflow PascalCase names never reached any wire, so they rename freely at the boundary.

Highest-leverage move: stamp codes into the three frozen shared auth/rate-limit constants in `lib/api.ts` — every v1 route flows through `getTeamFromRequest`, so that alone fixes the 401 overload API-wide.

**Forest:**

1. `api-error-codes/registry` — registry file; `code` on `ErrResult`/`err()` and rendering in defineRoute (incl. built-in 401/405/400/500); stamp the lib/api.ts constants and rest-api-utils helpers.
2. `api-error-codes/workflow-adapter` — mapping table, forward the code; resolves the workflow 409 overload. (Forwarding the RevisionConflict catch-up payload is a separate size decision, not here.)

**Later, separate:** the per-route adoption sweep (touches the same endpoint files as the idempotency legacy fix — sequence after it), and OpenAPI consolidation of 24 error schemas into one shared `Error` with a code enum as a 1.22.0 bump.

**End state (Phil, 2026-08-17): `code` goes required.** The optional field and the `code ? … : …` render guard are migration scaffolding only — they exist because legacy call sites bypass the seams and because statuses like 409 have no honest default (a filler code clients would branch on is worse than absence). Once the sweep gives every emission a specific code, flip the type to required, delete the guard, and declare `code` required in the OpenAPI `Error` schema. The sweep ticket carries this as its exit criterion.
