---
title: 5 · What moved under the branch
section: Restore a deleted audience
order: 50
project: restore-mvp
ask: lib/contact/handleBulkDelete.ts
lede: Two merged PRs invalidate the engine, and nothing else in the forest.
---

The forest was built 19–20 June and never pushed. Two changes landed on main afterwards.

**#9488 chunked the exports.** The dump is no longer one CSV. It is a prefix of paged files — `{teamId}/{actionId}/deleted-audience-{ts}/pages/000000.csv` — each carrying its own header, written as the [walker streams](src:lib/contact/handleBulkDelete.ts#/fetchNextChunk/). The engine's stated reason for loading everything at once, that the delete job built the whole dump in memory to write it, stopped being true.

**#9650 stopped enqueueing index jobs.** Delete no longer indexes, so the engine's symmetric re-index step now mirrors something that does not exist.

There is a third consequence with no PR behind it. `lib/storage.ts` has no list-objects helper, so the engine cannot discover how many pages a dump has. Delete already knows the number, so it should record it beside the prefix. Probing `000000`, `000001` … until a miss is the option to avoid: one transient 404 truncates a restore silently and still reports success.

Which means deletes that already ran recorded neither prefix nor count. **Those audiences are not restorable through this path** — the same only-works-going-forward property the contact-level snapshot work has.

Of the six branches, five hold. Only the engine needs rewriting, and the paged format makes it simpler: the page becomes the batch. A seventh branch belongs underneath — see [[restore-format]].
