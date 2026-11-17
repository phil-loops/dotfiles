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


## Round 5: findings are source-owned reader effects

Review diagnostics now claim the same revocable request sequence as type and definition lookups. Tickets are captured before scheduling a task and checked before the read and after its reply. A changed visit, source cursor, focus, picker, mode, displayed payload or branch source silences the effect. The shared wait presentation makes Esc cancellation explicit and clears a superseded hover even when the finding list is empty.

`ReviewFlags.Source` tracks tip generations for requested subjects. Store changes record A→B→A rather than reviving an old request when the tip happens to return. Positive findings are cached only for their exact generation; a missing review is asked again. Decoding requires a `flags` field: explicit null means no review, while transport failure, malformed data or a missing field means the read failed.

A picker holds finding identity and source context, never an executable row index. Activation recomputes stops after folding. A motion also computes its starting ordinal after the validated reply. Full-path labels keep matching basenames distinct. Branch-tip line coordinates can navigate an unscoped diff or a scope proven to end at the exact branch tip; older scopes can show the list but cannot reinterpret those coordinates as their own code.

The independent pass found and verified the older-scope coordinate mismatch, uncancellable pending work, stale hover presentation, index drift after folding, and the missing-key/null ambiguity. Each has an executable regression beside the existing navigation tests.

## Round 6: startup measurements name the work they time

`EventStream` reports snapshot fetch, decode and hydration separately while preserving its existing aggregate. All phase boundaries are captured before observer callbacks. A failed decode emits no completed-load sample. The benchmark preserves that callback and pairs the latest completed phase batch with its own readiness time.

The old cold benchmark created and attached its root before waiting for the stream, then timed an already warm layout. `--bench --cold-only` now constructs and lays out a fresh root inside the timer. Offscreen CPU raster is separate. Synthetic generation is labeled as local work; it supplies neither a network-fetch sample nor a stream-hello duration. A missing hello exits 2 without a content sample. Model timing begins after font registration and port discovery, so it is not process-launch latency. Page-specific asynchronous content on routes other than Forests may still be loading.

Sequential debug runs on 2026-11-17 used three samples per case. These medians validate phase attribution and scaling, not a latency percentile:

| Fixture | Fetch or local generation | Decode | Fresh root construction/layout | CPU raster |
| --- | --- | --- | --- | --- |
| Synthetic, 300 branches | 4.3 ms local | 24.0 ms | 55.2 ms | 17.6 ms |
| Synthetic, 1,000 branches | 14.5 ms local | 78.0 ms | 102.1 ms | 24.0 ms |
| Synthetic, 10,000 branches | 151.0 ms local | 786.5 ms | 921.9 ms | 61.1 ms |
| Captured 771 KB snapshot, 495 branches | 17.9 ms fixture fetch | 54.2 ms | 54.3 ms | 18.4 ms |
| Same snapshot, 250 ms server delay | 262.4 ms fixture fetch | 53.6 ms | 58.8 ms | 16.8 ms |

Hydration was 0.2–0.3 ms. A separate warm local `/state` read took 182 ms, with 52 ms reported by the server. Neither that observation nor offline replay explains the two historical 2.6-second v2 samples; a genuinely cold server capture remains missing. The current measurements identify snapshot decoding as measurable client work before any cache or server-lifecycle policy is changed. Benchmark review pages also answer `/gates-progress` locally because that GET can record a verdict.

Snapshot and patch decoding now parse their envelope once, letting the header, typed tables and raw tables read the same decoder. Typed failures remain lossy, unknown raw tables survive, and malformed envelopes still fail. Three sequential samples after the change put the captured snapshot's decode median at 51.4 ms and the 10,000-branch fixture at 698.9 ms, versus 54.2 and 786.5 ms above. This is a modest phase improvement; fresh root layout did not improve, and these small samples do not establish an end-to-end latency gain.

## Round 7: ancestry follows observed edges

A list cursor now has a per-pane monotonic revision, just like a source cursor. Reader requests cannot survive moving away and back, changing mode and returning, or a later page visit. An unfocused pane retains its own revision. Picker callbacks can accept exactly their own next closing transition; reopening an older callback does not recreate its authority.

Forest dependency reads retain their originating branch, reader, server epoch and git-domain version before the task is scheduled. Esc cancels the pending read. An accepted response resolves branches against that graph, deduplicates repeated edges and reports missing dependencies. A choice validates the original reader and graph again and resolves the selected identity anew. Review dependency pickers apply the same checks and also retain the displayed payload generation. These guards are deliberately conservative: a changed git-domain version requires a new lookup.

The independent producer audit found a larger factual gap: `stack-forest --node` and `/state` do not emit `requires`, although the native client already has that optional field. The older `/model` response includes edges but can be served stale without a source revision. Missing edge data therefore proves nothing about fan-in. Both native `:requires` paths now report that dependency data is unavailable instead of treating absence as an empty list and silently taking the parent. Tests include the actual node response shape, alongside explicit-edge replies for compatible servers. Supplying source-qualified dependency edges remains a separately tracked server capability; native ownership guards do not manufacture that evidence.

## Round 8: bench recordings retain their definition and namespace

Bench discovery matches the full repository and branch or project name. Documents use canonical file paths as identity and a digest of their captured bytes as the definition revision. Discovery inventories nested documents because the producer accepts them and stores recordings by basename alone. Colliding names produce unavailable status rather than borrowing another scenario's recordings.

The native reader delegates verdict calculation to `bench status`, off the main actor. It supplies a private frozen copy of the captured definition, preserving the producer's basename, then revalidates the original document. Changing A to B and back while the subprocess reads cannot substitute B's claims. Files are revalidated again before any future open action. Cancellation settles the owning load and prevents another status process from being launched; a newer subject owns its results even if an older read finishes later.

These are historical observations interpreted by the captured current definition. The producer records neither the original claim revision nor proof of the deployed build, so counts and timestamps must not become current-tip or ship-readiness evidence. No recordings, no applicable observations, and an unavailable status remain separate states. Tests exercise production-shaped isolated recordings, nested filename collisions, changed and deleted definitions, cancellation and interleaved subjects. The full native suite passes 640 tests.

The consumer is a bounded strip under the branch line or forest summary: at most two dated results, with the rest in Show. Active discovery includes top-level documents; nested and archived documents participate only in collision detection. A CLI label is not always a branch name (`group.branch ?? group.id`), so a shared group whose ID collides with an owned branch makes that branch's counts unavailable. Forest totals keep environments and recording times separate and check addition overflow.

`, T` opens the associated bench, choosing among full canonical paths when needed; `:bench.refresh` rereads results. A request retains its reader, server epoch and graph version before scheduling, accepts only its own next picker close, and revalidates the chosen definition off the main actor before invoking Show's explicit document-opening seam. Esc cancels pending opening in both Forest and Review. Practice replaces that seam and supplies an empty library. No bench is run by reading or opening it. Independent review findings on archives, header growth and ambiguous labels are encoded; 649 tests pass, and offscreen 1280/760 px fixtures include ten benches without consuming the diff viewport.
