# What John Hankles gets accepted for

The findings the `john-hankles[bot]` reviewer raises on loops PRs **that authors then accept**, ranked by
frequency × acceptance, plus the ones authors decline. Check the diff for the first list before a human
reviewer has to; stay quiet on the second. `stack-review-run` reads this file into its prompt at runtime,
and the push-ready and john-hankles skills point here, so edit it here and nowhere else.

Source: every Hankles inline thread on loops-so/loops, #9779–#11625 (1,689 threads, 342 PRs), read 2026-11-17.
Weighted by authors other than nalanj, who wrote 1,300 of the threads and accepts 90% through agent
replies. Everyone else accepts about 59%.

## Check for

1. **Stale prose.** After a rename, a removal or a behavior change: docs/*.md, JSDoc, header comments,
   runbooks or the OpenAPI spec that still describe the old behavior. A changed route whose generated
   openapi was not regenerated. (#11011, #11132, #11503)
2. **Duplication of what already exists.** A literal that equals an existing exported constant (#11256).
   A union or object type written out 3+ times: make it one named, exported type (#11623). Logic that a
   sibling helper already has. At 2 call sites, say nothing (see below).
3. **Orphans the deletion left behind.** A callee with no remaining caller, unused imports, constants or
   section headers, commented-out code. (#11011, #10281, #11517, #11568)
4. **Tests that cannot fail.** A test that exercises a rebuilt copy instead of the exported unit (#10540).
   Asserting only `calls[0]` when the code makes several calls (#11365). Not asserting the call's arguments
   (#11557). No case for the branch that fails (#11464).
5. **No test for a new exported model, query, parser or job function** (AGENTS.md; #10382). Trivial pure
   helpers are exempt.
6. **Silent failures.** A new `catch`, `??` fallback, early return or `|| echo` that drops an error where
   the sibling code logs or alerts. (#11122, #10106, #11285)
7. **Migration safety.** A type change that rewrites the table (#11270). `NOT VALID` and `VALIDATE` in the
   same migration file (#11612). The previous release breaking against the new schema (#11231). The Prisma
   schema drifting from the migrations. Squawk findings.
8. **Test hygiene.** The default-env / query-env import comes first (#11620). Unique ids, not fixed ones.
   Nothing written outside the test transaction (#10523). Waits have bounds (#10560). No dependence on a
   local `.env` (#10278).
9. **Scope.** Hunks the branch description does not explain, especially in tests and shared helpers.
   (#11625, #11559)
10. **Casts.** `as any` and `as unknown as`. On mock calls use `mock.calls[0]!.arguments[0]`, not a cast
    (#11625). An `any` on a mock's parameter (`mock.fn(async (_input: any) => …)`) is the same hole: type
    the mock with the real signature, `t.mock.fn<DepsType["fnName"]>(…)` or `mock.fn<typeof fn>(…)` (#11627).
    Authors accept these 95% of the time.
11. **Bypassed injection.** A function that takes `deps` but calls a side-effecting collaborator (db, network,
    queue, clock) directly. (#10382, #11619)
12. **Secrets in logs.** A token, key, password or full credential-bearing URL in a log or error message. (#11385)
13. **Filters the siblings apply.** `softDeleteAt: null`, `teamId` scoping and ownership checks that sibling
    queries on the same table apply and the new one leaves out. (#10110, #11196)
14. **Unbounded reads.** A new `findMany`, `IN (...)` or backlog loop with no `take`/limit (#10986). Admin-only
    paths that are bounded in time are exempt.

## Stay quiet on (authors decline these)

- "This should be a follow-up / the next PR in the stack." At most a note, never a blocker.
- Anything the author marks intentional or that the ticket asks for.
- Edge cases that cannot realistically happen.
- Serverless-freeze or cold-start worries. Loops runs on long-lived pods on k8s.
- Moving pure deterministic helpers or logging into `deps`. (#11605, #10456)
- Extracting a helper shared by only 2 callers. (#10181, #11496)
- Tests for trivial code. (#10102)
- Metric tag cardinality. (#10977)
- Log throttling and other product-taste calls.
- Empty-input guards in queries. (#11074)
- Explicit type predicates where JS narrowing already works. Phil prefers the narrowing. (#11623)
