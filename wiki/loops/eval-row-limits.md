---
title: What a column cannot promise
section: Email safety evaluation
order: 42
project: eval-findings
ask: models/safety-evaluation.ts#toStoredEvaluation
lede: Three bug classes vanished; two survived, because schemas cannot express them.
---

The branch was finished and ready to push when the storage problem in [[eval-evaluation-is-a-row]] was diagnosed. The argument for fixing it anyway was timing: **the pipeline had never run anywhere, so there were zero rows to migrate.** Every day that stayed true was the cheapest this would ever be; the first real row made it permanently expensive.

Once the columns were real, three bug classes stopped existing — "the envelope is malformed", "the envelope lacks the revision", "this isn't an envelope". Three tests were deleted. Not lost coverage: a `NOT NULL` column cannot be any of those. Fewer tests because fewer things can go wrong is the good kind.

Two things survived, because no schema expresses them.

**A present revision is not the right revision.** `NOT NULL` guarantees *a* revision, not the one captured when the job was queued rather than whatever the email says by the time it runs. A sender can edit in between. That test survived.

**Stored is not readable.** Postgres will happily hold evidence carrying the right version marker but missing the facts the rules go on to walk; the failure then happens far away, looking like something else. Reading a row back is a real check that throws on a row it cannot trust — a corrupt record is not an evaluation, and scoring a candidate on a guess is worse than refusing.
