---
title: 6 · The shared format
section: Restore a deleted audience
order: 60
project: restore-mvp
ask: lib/contact/handleBulkDelete.ts
lede: The writer and the reader agree on columns by coincidence. That should be a file.
---

The dump's column order is defined twice: once in the [header the writer builds](src:lib/contact/handleBulkDelete.ts#header) and once in the reader's own copy of the same list. Two hand-maintained arrays in two files, agreeing by coincidence. Add a contact property, or reorder the fixed block, and restore mis-parses without erroring — it just writes the wrong values into the wrong columns.

So the format wants to be a module both sides import: the header builder, the row writer (already extracted as a local helper on main), and the row parser. Nothing else changes about either side.

That makes it a capability with two dependents, which puts it at the **bottom** of the forest as its own base, with delete and the engine fanning in above it — not folded into whichever branch happened to need it first. The forest becomes seven nodes, and the new one merges before either consumer.

It is also the only place the paged format is written down. Each page repeats the header, so the parser reads per-page rather than assuming a single header for the whole dump; a page whose header disagrees with the team's current properties is where a mismatch should be caught and reported, rather than silently mapping column six onto the wrong field.

Open questions across all of this are collected in [[restore-decisions]].
