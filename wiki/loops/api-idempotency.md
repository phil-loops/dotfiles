---
title: Idempotency, first-class
section: API foundation spikes
order: 20
project: api-idempotency
ask: lib/middleware/processIdempotency.ts
lede: The header promises retry-safety; the implementation is a 24-hour mutex.
---

Two endpoints accept `Idempotency-Key` today. The [implementation](src:lib/middleware/processIdempotency.ts#processIdempotency) is `SET key "LOCK" EX 86400 NX` — no request fingerprint, no stored response. Any reuse gets 409 "already been processed", so the one case the header exists for — retry after a timeout on a request that succeeded — is unrecoverable: the client cannot learn what happened or get the original result. The OpenAPI example ("Idempotency key already used with a different request body") describes Stripe semantics the code never had.

Worse, both call sites burn the key **before** most validation: on events/send any 400 after the claim consumes it; on transactional the 404-for-bad-id does. And nothing ever releases a key — a handler crash strands the operation for 24h.

**Target: Stripe-style replay on Valkey.** Claim the key with `{state: in_flight, fingerprint: hash(method+path+body)}` under a short self-healing TTL (60–120s — a crashed handler's claim expires and the retry re-executes). On completion store `{state: done, status, body}` for 24h. Retry with matching fingerprint replays the stored response verbatim; different fingerprint gets the 409 the spec already promises; a duplicate while in flight gets 409 + `Retry-After` (never hold connections open waiting).

**Rollout: new-endpoints-only.** Replay becomes a per-route `idempotency` option on `defineRoute` — trivial to capture there because handlers return `RouteResult` values instead of writing to `res`. The two legacy endpoints keep their documented 409-on-reuse but get the burn/crash fixes (claim after validation, release on failure), which no client could have depended on. The metrics-report-create endpoint is the first replay consumer; its handler composes natural-key job dedupe underneath via the dormant `insertJobIfAbsent`/`findByDedupeKey` helpers in queries/job-status.ts.

**Forest:**

1. `api-idempotency/core` — claim/replay store: fingerprint claim, done-transition with stored status+body, replay lookup, in-flight 409, crash self-heal, release-on-failure; DI'd, unit-tested (race, crash-expiry, mismatch, body-size cap).
2. `api-idempotency/legacy-fix` — transactional + events/send: move the claim after all validation 4xx paths, adopt release-on-failure; documented contract unchanged.

**Deferred until the error-codes registry lands in defineRoute** (both edit the same seam): `api-idempotency/route-option` — the `defineRoute` `idempotency` config + first consumer.
