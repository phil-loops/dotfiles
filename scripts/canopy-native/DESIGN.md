# Canopy: contracts before features

Canopy is a reader for a branch and the work around it. The main activity is reading; actions, evidence, and machine state support that activity. A capability is complete when its contract holds through navigation, asynchronous replies, resizes, and a relaunch.

## Principles and enforcers

| Principle | Enforcer | Strength | Test |
| --- | --- | --- | --- |
| A place names both the content and the position within it | `Place`, `CodeNav`, `ReviewPageState` | Type and shared navigation path; asynchronous consumers need auditing | `NavTests`, `MotionRulesTests` |
| Layout describes the content actually displayed | `DiffLayout`, `DiffPiece`, `RowInfo.layout`, source marks | One source/storage mapping and physical layout path for rendering, hit testing, search and cursor placement | `DiffLayoutTests`, `ReviewTests`, `PinnedHeaderTests` |
| A command names its target; movement never silently becomes a write | `Verbs`, command registry, `Runner`, confirmation layers | Types and shared dispatch path | `ShellTests`, `ShipRulesTests`, `ShipTests` |
| A result belongs to the version and request that produced it | `ReaderContext`, synchronous lookup tickets, tree-keyed gates/evidence | Shared path fences navigation, focus, words, side, and picker revisions | `LookupTests`, `EvidenceTests` |
| State reports observations, not stronger conclusions | `GatesRun.rows`, `isRunning`, terminal gate verdicts | Shared reducer distinguishes skipped, stopped, failed, and waived | `GatesRunTests` |
| The reader's available width does not follow keyboard focus | fixed pane allocation, canvas width measurement | Shared layout path | offscreen renders and motion benchmarks |

Strength means a type or shared code path enforces the rule. A caller convention is an open design gap, not a guarantee.

## Work order

1. **Trust the facts.** Distinguish a gate that failed from one that never ran; reject obsolete asynchronous results; keep confirmations bound to the code shown.
2. **Keep reading continuous.** Give each hunk a layout that all drawing, hit testing, search, and keyboard movement share. A missing side is a layout state, not a guessed character count.
3. **Make the margin useful.** Guide the reader to unresolved work and their current location without repeating the header. Keep the complete file list available by name. Focus alone must not resize the document.
4. **Keep the next step explicit.** Readiness, evidence, and machine jobs name what is known and what needs a deliberate action. No background staging requests or publication.
5. **Measure the slow paths.** Separate hydration, server reads, and drawing before changing their architecture. Reversal telemetry must distinguish comparison from correction before it becomes a success metric.

Each slice stands alone, includes regression coverage, and lands as a local commit with a PR draft. Existing key meanings remain stable unless a demonstrated conflict requires a change.

## Backlog audit: 2026-11-16

The initial list has 30 unfinished items. An API-evidence capture item is owned by another session. Do not take it over. A few lookup-key subitems already exist in code (`e`, workspace symbols, and findings); verify those separately from the remaining work.

GitHub pending-review rollout, scheduled ref archival, and staging credentials are consequential operating-policy decisions. This pass can prepare code and recommendations, but it cannot enable them or perform their live acceptance steps. The personal rule forbids publishing or commenting on GitHub.

The old width bug is instructive: a modified file with only deletions was treated as if its new side did not exist, even though context was still rendered there. Commit `9989acde` restores space for both sides; a real TextKit test catches the resulting 21-line wrap at three window widths.

## Round log

### Round 1: audit the existing guarantees

- Establish a full native test baseline.
- Obtain an independent read-only audit of place preservation, layout, command targets, and versioned results.
- Trace incomplete gate journals from the producer to the renderer. An environment failure ends a run before planned checks start; those checks must not be presented as failing code.
- Preserve existing work in the shared checkout. Author in an isolated local worktree and land only explicit paths through `patch-land`.

## Round 1: ownership through interruption

The independent pass stressed navigation between request and response, failures after newer editing, old persisted drafts, and terminal journals missing intermediate events.

| Finding | Verdict and encoding | Verification |
| --- | --- | --- |
| Undo could use the currently open branch | Confirmed; inverse commands carry the original branch and repository | `ShipTests` navigates before undo |
| Missing repository metadata could silently select the default repository | Confirmed; every nonempty named repository keeps its URL prefix | `RunnerTests.atRepoNeverDropsANamedRepo` |
| A failed save could recover a draft into another branch or replace newer words | Confirmed; branch-owned composers and revision-checked recovery retain the original words | `ComposerTests`; upgrade recovery explicitly claims old unowned drafts |
| A delayed lookup could navigate after the reader moved, including moving away and back | Confirmed; request tickets capture monotonic visit, focus, source-cursor and picker revisions before scheduling work | `LookupTests` holds and releases replies around those transitions |
| Gate failures without `done` or `plan` disappeared; unstarted work looked failed | Confirmed; terminal verdicts supply outcomes and names, unstarted gates are skipped, interrupted gates are stopped, accepted bypasses are waived | `GatesRunTests` replays producer-shaped JSON, including empty results and process-liveness races |

The sharper ownership rule is: saved words and inverse actions retain their named subject; transient reader effects require the original reader revision. Recovery preserves work without taking over newer editing. A terminal observation ends live clocks even when a process or optimistic overlay still says running.

The layout re-scan found separate source, storage and display coordinates being treated as one number. Old continuation text is painted outside text storage, so visible words are absent from search and cursor movement. Unicode and tabs can shift storage offsets away from painted columns. The next encoding must name those coordinates and make one row plan serve drawing, hit testing and navigation; another width heuristic would leave the same contract unenforced.

## Round 2: one row plan for reading

Source UTF-16 positions, text-storage UTF-16 positions, and painted columns are distinct coordinates. `DiffPiece` maps the first two; `DiffDisplayRow` carries the actual tab stops and column boundary. A semantic diff row keeps its key and anchors while producing any number of physical rows. Every displayed continuation lives in text storage.

The shared plan gives each hunk only the sides its changes need. Addition-only and deletion-only hunks use the full width with unchanged context shown once. Replacement hunks align both sides; panes below two readable code columns stack the sides. Word and search marks remain in source coordinates, and click/hover, syntax marks, code navigation, editor placement, and z-positioning consume the plan.

The independent re-scan found two holdouts: z-positioning still aimed at the first paragraph of a wrapped source row, and a queued resize callback could override a newer scroll. Cursor placement now resolves the selected source piece. Reflow preserves a visible source cursor synchronously; no deferred effect can reclaim the viewport. Tests cover a name deep in an old continuation, Unicode and tab round trips, actual TextKit columns, narrow stacking, source hit testing, zt/zz/zb, and reflow followed by a newer positioning request.

The 6,061-stop fixture builds the mapped document in roughly 0.7 seconds and moves by key in roughly 0.9 ms on the development machine. The executable regression limits remain 3 seconds and 20 ms. Token lookup begins at a binary-searched source boundary so a long wrapped line does not repeatedly scan all its syntax tokens. Offscreen renders at 800 and 1460 points verify mixed hunk modes against an isolated read-only fixture server.


## Round 3: return to work without moving the reader

The margin had accumulated proposals for description, history, gates, and a file list. Those already have owners in the page header, branch line, shipping strip, and changed-file picker. The guide now has one responsibility: return to a flagged change or an unresolved, non-outdated thread. It opens on demand over the document. Its allocation is independent of focus and selection; the reading document never reflows to accommodate it.

| Principle | Enforcer | Verification |
| --- | --- | --- |
| Selecting work does not navigate | Guide pane selection is separate from activation through the registry | Keyboard guide tests and offscreen wide/narrow renders |
| A destination names the displayed source | Exact current payload/commit readiness plus branch/tip/stretch entry keys | Held tip, base, and scope reload tests; loading is distinct from loaded empty |
| An entry opens its named subject | Activation re-resolves block/thread identity; flags have no nearest-line fallback | Disappearing flag, stale selection and scope-change tests |
| Read state is not a presentation workaround | Threads open the existing conversation rather than a folded inline stop | A thread on fully marked-read code opens without changing any mark |
| A file is reachable regardless of file count | Shared complete file picker with full path labels and current-context validation | One-file keys, matching basenames and replaying an older picker |
| Progress says what was observed | Explicit marked-read counts; flags remain actionable in the queue | `Mark.flagged` means read and set aside; empty queue makes no completion claim |

The independent pass found that `diffHere` only proves branch identity: the previous payload deliberately remains visible during a same-branch tip/base reload. The guide's shared readiness predicate requires the exact current payload key before minting destinations. An immutable commit scope requires its loaded commit list. A picker created before a scope change cannot act after it.

A further ownership scan found that the viewed/flag write path still captures the ambient page for inverses and rollback. This is queued as the next separate capability: marks must retain the originating repository and branch and must not restore an old dictionary over newer marks on another page.


## Round 4: mark writes retain their subject and their lineage

Read and flagged marks are repository-wide. An optimistic mark therefore belongs to its repository, while the write and its inverse retain the original branch and flag location. `ReviewMarks` is the single owner of optimistic values; page navigation only changes which repository it reads.

Each write receives a receipt for its touched keys and the earlier receipts those values came from. A failure removes only the failing intent. A newer intent survives, and restoring a prior value walks past any prior writes that already failed. This matters for a flag followed immediately by an unflag: two failures must not resurrect the first failed flag. Successful and pending earlier values remain distinguishable. Receipts no longer referenced by a current value or its predecessors are discarded.

A pending value cannot retire merely because an old server value happens to equal it. HTTP acceptance permits matching-value reconciliation against the originating repository. Confirmation is recorded per key even below a newer pending head; rollback falls through confirmed ancestors to current canonical state. This retains the current server-value confirmation contract. An audit found that the server returns write counters without their producing epoch; using those counters in a new reducer would not strengthen confirmation across restart. The protocol needs an epoch-qualified acknowledgement in the viewer lane before clients can use it as an ordering proof. That separate work remains tracked; no bare counter is used to retire a mark receipt. Settlement, inverse creation, flag metadata and rollback all retain their original subject. Tests cover cross-repository navigation, unchanged newer values, both two-failure orders, a held real command refusal, settlement from another repository, flag metadata on undo, and every mark/outcome/delivery-order combination for three overlapping writes.
