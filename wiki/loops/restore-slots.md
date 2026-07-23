---
title: 3 · The freed slots
section: Restore a deleted audience
order: 30
project: restore-mvp
ask: packages/prisma/schema.prisma
lede: Delete frees two unique slots. Probing only one fails a whole page, not a row.
---

The scramble is deliberate, not sloppy. Writing `{id}@unsubscribed.com` and nulling `userId` vacates both unique slots on the contact — `[email, teamId]` and `[userId, teamId]` — so someone can sign up again with that address afterwards. That is the behaviour delete is *for*.

Which means by the time a restore runs, either slot may belong to a live contact. A row whose slot is taken cannot come back; it gets dropped and counted as skipped.

The June engine probes email only:

```
SELECT lower(email), "userId"
  FROM "Contact"
 WHERE "teamId" = :teamId
   AND "softDeleteAt" IS NULL              -- live rows only
   AND (lower(email) = ANY(:emails)
        OR "userId" = ANY(:userIds))       -- the missing half
```

Adding the second half is one clause, and it matters more than it looks. The revive is **one UPDATE for the whole page**, so an unprobed userId collision does not lose the one contact that collided — it raises a unique violation that fails all twenty thousand rows in that page. Probing both slots is what keeps a page from being all-or-nothing.

The sibling contact-level work already probes both; this is the audience-level engine catching up.

Counts are a report, not an accounting identity: a row can be neither restored nor skipped when someone already restored it. Whether that deserves its own counter is open in [[restore-decisions]].
