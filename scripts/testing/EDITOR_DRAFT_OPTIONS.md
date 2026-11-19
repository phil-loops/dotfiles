# Editor draft storage experiments

These modules are an isolated comparison, with no production imports or routes. Every Git writer
requires a disposable bare repository marked `canopy-draft-lab`; fixture creation optionally reads a
local source repository into a shared-object clone. No source refs, remote refs or running editors change.

| Option | Editor filesystem | Publication |
| --- | --- | --- |
| `workspace` | Complete detached worktree | Rebuild a private index, apply the declared mutations, write its tree |
| `hybrid` | Complete detached worktree | Rebuild only affected Git trees from the mutation journal |
| `objects` | Only explicitly opened files | The same Git-tree publisher as `hybrid` |

All options use the same SQLite WAL journal with `synchronous=FULL`, immutable base commit, expected
draft version, idempotent mutation IDs, frozen publication, retained commit anchor, expected-tip ref
update and receipt replay. Git commands use scoped `core.fsync=all` and `core.fsyncMethod=fsync`.
Written content remains in SQLite until freezing, so Git pruning cannot discard an uncommitted edit.
Process death is tested; physical power-loss durability is not established by these experiments.

The mutation API accepts canonical Git blob bytes and explicit modes, including binary data,
symlinks and executable files. It does not implement Git clean/smudge filters, working-tree encoding
or language-specific transformations. Directory replacement and overlapping parent/child manifests
are refused. Untouched Git entries are retained. This is a storage protocol comparison, not a complete
replacement for Git staging or a deployed editor integration.

Every write must be reported by its owner. The real Helix harness explicitly imports its declared
file after successful editor exit. It does not install a general Helix save hook. An opaque writer
can mark the journal uncertain; freezing then refuses until a future reconciliation protocol handles
it. An unreported external process remains outside the tested contract. The existing production
attachment leases would still be needed to own editors and their filesystem projections.

Run from the dotfiles root:

```sh
python3 -W error::ResourceWarning scripts/testing/test_editor_drafts.py
python3 scripts/testing/bench_editor_drafts.py bench /private/tmp/draft-bench --samples 8
python3 scripts/testing/bench_editor_drafts.py bench /private/tmp/draft-loops --files 0 --samples 8 --source /path/to/repository
```

The benchmark randomizes option order within each repetition, uses fresh drafts/projections and a
closed object reader/cache for each trial, verifies published bytes, and reports raw samples plus
median, median absolute deviation and extrema. Fixture generation and cleanup are outside measured
intervals. OS caches are not flushed. SQLite setup, actual materialization and the selected document
read are included in open latency; mutation recording, tree/commit/ref publication are included in
save latency. These are storage measurements, not app paint or language-server readiness.

`EditorDraftOptionsTests` is opt-in with `CANOPY_DRAFT_OPTIONS=1`; `CANOPY_DRAFT_SOURCE` selects a
local source repository. It opens a real Helix process in SwiftTerm, edits a declared file, quits,
publishes and verifies exact bytes and receipt replay. It balances all six option orderings.
Its open interval includes helper process startup, projection preparation and the first normal-mode
editor frame. Save includes editor exit, explicit host capture and durable publication. The text-only
test disables LSP; import correctness is probed independently with an actual `tsgo` binary:

```sh
python3 scripts/testing/bench_editor_drafts.py fixture /private/tmp/draft-imports
python3 scripts/testing/bench_editor_drafts.py probe /private/tmp/draft-imports /path/to/native/tsgo
```

The probe opens only `main.ts` and project configuration through the adapter, then asks `tsgo` to
resolve an imported binding to unopened `helper.ts`. It separately verifies that the draft reader
returns the correct helper content. This distinguishes a complete Git namespace from the filesystem
namespace an unchanged language server actually reads.
