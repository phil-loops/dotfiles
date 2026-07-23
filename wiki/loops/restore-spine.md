---
title: 1 · The spine
section: Restore a deleted audience
order: 10
project: restore-mvp
ask: lib/contact/handleBulkDelete.ts
lede: Delete scrambled the rows in place. Restore is the same UPDATE, run backwards.
---

Bulk delete never destroyed anything. It dumped every contact to S3, then overwrote the identity fields in place — email became `{id}@unsubscribed.com`, names and attributes blanked, `userId` nulled, `softDeleteAt` set — in [one statement](src:lib/contact/handleBulkDelete.ts#nukeContacts).

The rows are still there, under the same ids. So restore is not an import: it is that statement inverted, keyed by contact id. Everything hanging off the contact — events, emails, list memberships — was never touched and returns the moment the row is undeleted.

Three stages, with two boundaries that matter:

**Request.** An admin picks a dump. The model checks it is real and not already running, enqueues, and returns *queued*. The answer stops here; nothing downstream is synchronous.

**Worker.** Take the lock, stamp `processing`, run the engine, stamp the counts, release.

**Engine.** For each page of the dump: read it, parse it, find which email and userId slots live contacts now hold, write the survivors back.

One page is in flight at a time and nothing accumulates across pages, so memory stays flat no matter how large the audience. That property is why the engine has to be rebuilt against the paged format — see [[restore-drift]].

The two conditions that make all of this safe to re-run, and safe to run late, are in [[restore-guards]].
