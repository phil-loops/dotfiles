---
title: 4 · What comes back
section: Restore a deleted audience
order: 40
project: restore-mvp
lede: Most of the graph returns for free. The omissions are choices, not gaps.
---

Because delete only ever rewrote columns on the contact row, everything keyed by contact id survived it untouched.

**Free — never touched.** Events, emails, opt-ins and mailing-list memberships are all keyed by `contactId`. They come back the instant `softDeleteAt` clears; the engine does nothing for them.

**Restored from the dump.** Email, first and last name, `userId`, source, user group, notes, subscribed, and every custom contact property.

**Deliberately not restored — workflow bookmarks.** Delete cancelled them, and they stay cancelled. The contact returns; their position in a running workflow does not. HubSpot makes the same call on merge, and the alternative — resuming someone mid-sequence weeks later — sends mail nobody expects.

**Not touched, so nothing to undo — `createdAt`.** It rides in the dump but is never written back. Delete never changed it.

**Gone by choice — the search index.** Delete stopped enqueueing index jobs entirely, so restore mirrors nothing by omitting them. See [[restore-drift]].

One consequence worth stating plainly: a contact property added *after* the delete has no column in the dump, and one removed since no longer casts. Both degrade quietly rather than failing. That is the right trade for a recovery tool — a restore that refuses because the schema drifted is worse than one that returns everything it still understands — but it means a restore is not guaranteed byte-identical to the pre-delete state.
