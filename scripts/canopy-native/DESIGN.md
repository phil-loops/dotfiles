# Canopy: contracts before features

Canopy is a reader for a branch and the work around it. The main activity is reading; actions, evidence, and machine state support that activity. A capability is complete when its contract holds through navigation, asynchronous replies, resizes, and a relaunch.

## Principles and enforcers

| Principle | Enforcer | Strength | Test |
| --- | --- | --- | --- |
| A place names both the content and the position within it | `Place`, `CodeNav`, `ReviewPageState` | Type and shared navigation path; asynchronous consumers need auditing | `NavTests`, `MotionRulesTests` |
| Layout describes the content actually displayed | `DiffLayout`, `DiffPiece`, `RowInfo.layout`, source marks | One source/storage mapping and physical layout path for rendering, hit testing, search and cursor placement | `DiffLayoutTests`, `ReviewTests`, `PinnedHeaderTests` |
| A command names its target; movement never silently becomes a write | `Verbs`, command registry, `Runner`, confirmation layers | Types and shared dispatch path | `ShellTests`, `ShipRulesTests`, `ShipTests` |
| A result belongs to the version and request that produced it | `ReaderContext`, synchronous lookup tickets, tree-keyed gates/evidence | Shared path fences navigation, focus, words, side, and picker revisions | `LookupTests`, `LookupSettlementTests`, `RenameOwnershipTests`, `EvidenceTests` |
| State reports observations, not stronger conclusions | `GatesRun.rows`, `BenchLibrary`, `MachineRuns` | Shared paths distinguish verdicts, historical responses and reported document state | `GatesRunTests`, `BenchLibraryTests`, `MachineRunsTests` |
| Local document reads bound input and retain its file version | `LocalDocumentFile.read` | Regular-file descriptor, capped reads, paired bytes/mtime | `LocalDocumentFileTests`, `MachineRunsTests` |
| Work context preserves status, timestamp precision and literal input attribution | `WorkContext`, `RecordedWorkInput`, shared context views | Exact linked subjects, explicit first-section input records, tracker-only date labels and read-only completed-item reveal | `WorkContextTests`, `WorkContextNavigationTests` |
| Every work instruction survives independently of agent progress | `WORK-CONTEXT.md` recording workflow | **Convention only; open.** No source identity or transactional capture boundary | Round 25 |
| Current completion is based on the newest captured direction | No runtime receipt or producer revision check yet | **Unenforced; open.** Attribution does not prove delivery or freshness | Round 25 |
| Cancellation revokes pending work before external handoff | `BenchOpening`, `MachineRuns.open`, `ReviewGitHubOpening` | Shared effect boundaries end the cancellable phase before invoking the external seam | `BenchOpeningTests`, `MachineRunsTests`, `ReviewGitHubOpeningTests` |
| One discoverable action can retain compatibility names | `CommandDiscovery`, registry alias metadata | Eligible canonical projection with raw exact-ID execution preserved | `CommandDiscoveryTests`, `CanonicalCommandTests` |
| Syntax coordinates retain their immutable object and displayed grouping | `ReviewUnits.Source`, raw/derived keys, `ReviewSyntax`, opaque prepared context | Source-qualified cache and reader-owned application after both awaits | `SyntaxSourceTests`, `ReviewSyntaxTests` |
| A measurement retains its client, phase, support and budget | `DashboardReport`, `DashboardTiming`, revision-owned window loads | One projection preserves identity and unavailable evidence; responsive phase layout | `DashboardReportTests`, `DashboardTests` and offscreen fixtures |
| A queued mutation rechecks its native facts immediately before sending | `Write.refuseBeforeSend`, Runner's sole post path | Optional shared send boundary; producer atomicity remains separate | `WritePreflightTests`, `HelixOwnershipTests` |
| An editor commits only to its original owner and consumes quit once | `HelixOpen.source/session`, token-bearing terminal callbacks, `HelixLanding` permit | Type and one registered write path; explicit repository, branch, full head and directory | `HelixOwnershipTests` |
| A delayed editor return needs its current reader intent and acknowledged object | `HelixReturn`, `takeHelixReturn` | Monotonic reader stamp, session identity and exact full commit; file windows retain identity | `HelixOwnershipTests` |
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

## Round 9: a reported run is a document, not a process table

Machine reads the supported live-run registry and the referenced live documents off the main actor. The document supplies its current title, reported state and counts; the registry title and opened time cannot replace those facts. Only explicit done/failed states are terminal. Paused and unknown states stay visible with their reported names, and zero or overshooting counts never imply completion. A running report becomes `stalled?` after the document's own stale interval. Its timestamp comes from the same opened file descriptor as its bytes, including through atomic replacement.

The independent pass found that an initial size check plus `readToEnd` did not bound I/O: a FIFO or `/dev/zero` could hold the entire catalog indefinitely. `LocalDocumentFile` now opens nonblocking, rejects nonregular files, caps both initial size and actual reads, checks cancellation between chunks, and rejects an in-place size/mtime change. Bench discovery adopts that same reader. Tests cover pipes, devices and oversized files. Cancellation stops being offered immediately before handing a validated document to Show, and completion feedback remains request-qualified.

Reported documents join the existing queue pane with full-path `run:` identities and their own scope. They cannot resolve as `q:` process rows or enter a kill route. The queue follows its keyboard cursor. Each report opens in Show by the main/open verb after reader, registry membership, mode and title validation; progress is allowed to change. Canceled or older refreshes cannot replace a newer snapshot. Malformed registry peers do not hide valid reports, read errors preserve dated last reports with an unavailable notice, and the practice world replaces both file reads and the opening seam.

Machine's reports remain available while preview/substrate reads fail. Until preview discovery succeeds, the page neither claims that nothing is serving nor offers to start main based on that absence. Offscreen wide and narrow fixtures exercise this state, paused/unknown/stale reports and keyboard movement. The full suite passes 663 tests.

The producer exposes no immutable job identity, PID, process-start token or hosted/local field. Canonical path identifies the document only. Native therefore makes no process-liveness, slot-ownership or hosting claim. Joining heavy-turn slots and moving the activity tint to Machine require explicit producer and Show changes outside this lane; the larger tracker item remains open for those contracts.

## Round 10: ancestry choices keep the graph that offered them

The follow-up scan found that the review child chooser still retained unfenced callbacks, even though dependency choices were already guarded. The child helper also serves recursive tip traversal. It now captures the original branch, server epoch, git-domain version and reader after each picker opens, accepts only that picker's next close, and re-resolves the chosen identity. Valid tip traversal through a fork remains covered. A replay from another branch or a graph change cannot move the reader. Cancellation feedback is asserted at the cancel action, before the quiet line's intentional expiry; delayed response assertions still verify no navigation.

The independent scan found the corresponding Forest child-label path needs an earlier boundary: the label layer moves the cursor before dispatching its target command. A source check inside the command is therefore too late. `LabelTarget.acceptsPick` now validates a captured target before any jump, focus, cursor or command effect. Forest child labels retain their original reader, parent, server epoch and graph version and recheck the selected child's current parent. The on-screen label chooser stays intact. An unchanged choice still works; a child reparented elsewhere in the same visible forest is refused without movement or another jump. The shared boundary passed 671 tests before its consumer was added.

## Round 11: discovery presents actions while execution retains names

The named ancestry commands had two palette entries for one action: a global `parent`, `child` or `requires` and its page implementation. Explicit alias metadata now records that relationship without changing command initializers, keymaps, Runner dispatch or compatibility IDs. A shared projection first receives each consumer's eligible commands, then folds compatible keyless aliases into a live canonical command and collects their search terms. Missing targets, cycles, argument differences and keyed aliases fall back visibly. Eligibility precedes query matching, so a search for a legacy page name finds the canonical action rather than changing which command is available. Only eligible aliases supply synonyms; another page's names do not leak into the current search.

Exact IDs and `<id> <argument>` still resolve against raw commands before projection. This preserves the command line's argument extraction and direct compatibility invocation. Menu keeps its grouping and scope ordering, and a keyless row teaches its real `:name`. The ancestry routers now use the underlying page command's availability; a Review or Forest route alone does not prove a branch exists. Tests cover both pages, exact legacy execution and arguments, scoped synonyms, unavailable branches and a consumer-specific quiet-canonical fallback. The shared layer passed 676 tests before consumers, and the full consumer gate passes 682. Independent review found no remaining concrete gap.

## Round 12: measurements keep the evidence needed to interpret them

Dashboard rendered mixed native and retired-web command rows without client labels, used execution counts beside a sparsely sampled feedback p95, and titled every row over budget even when the producer ranked a command by its settled phase. The producer already supplies separate support and budgets for both phases. The native projection retains them, filters the chosen client before limiting the view, and keeps the producer's usage/overrun order without calling it absolute latency order. Native is the default; the client is an ordinary local registry command. An absent native sample remains an explicit empty window even when older clients have data.

Row identity is the full client and command name, independent of rank. Duplicate and unnamed rows are withheld with a count; percentiles are never averaged to repair ambiguous input. A phase needs positive sample support and a finite nonnegative p95 before it can earn a verdict. Its budget must be finite and positive, and the ratio finite. Zero latency remains valid with support. Execution counts, feedback samples and settled samples stay separate. Numeric formatting cannot convert nonfinite values into integers. The shared projection passed 687 tests.

Window changes revoke the displayed summary synchronously, while request generation, captured days, cancellation and returned days fence replies. Independent review found a second boundary: 30→90→7→30 can coalesce before SwiftUI observes the intermediate task IDs. The view therefore keys loading by a separate monotonic window revision, not the day value or load counter. A canceled request whose transport still returns cannot publish success or failure.

The layout re-scan found that putting phase evidence in a horizontal scroller made hidden budgets inaccessible by keyboard. The ledger now uses the available width and switches from aligned phase rows to a stacked phase layout when the full row does not fit. Cursor identity and scroll following use the same semantic row key.

Independent review also found threshold evidence rounded away: 16.8 ms and a 16.7 ms budget both printed as 17 ms, beside a failing 1.0× label. Formatting now retains six significant digits and a just-over threshold reads >1×. The final consumer gate passes 692 tests; isolated wide, narrow, empty-native and historical-client renders keep the client and both phase budgets visible. No material gap remained in the final independent pass.

## Round 13: syntax belongs to an object, grouping to a displayed diff

The syntax producer already accepts an immutable commit and returns the resolved full object name. Native requested a mutable branch and discarded that name, while its cache omitted the selected commit scope. Warming a current-tip file could therefore lend both declaration coordinates and derived changed-block membership to an older diff. Supported syntax now travels by repository, immutable new-side object and full path; responses must name that object (including verified full-name expansion of an abbreviated object). Raw declarations are reusable only for that source. Derived grouping also names the displayed context and payload generation. Background warming follows that context and readiness. Both caches are bounded.

Missing fields, partial arrays, mismatched object names and invalid spans cannot become a successful empty tree. Explicit null grammar support and producer failures preserve their reason and are retried; qualified empty arrays remain a real cached observation. Block-level read marking keeps its existing fallback while syntax is unavailable. Integration pages whose assembled ref has no immutable new-side name cannot manufacture one; they remain unavailable for syntax motion. The current branch diff protocol itself still lacks a source SHA in its payload, so this client uses the source named by its current snapshot and payload key; qualifying node responses is a producer contract, not proof supplied by this change.

The source model passes 700 tests, including scoped sources, the same immutable source under another displayed diff, response mismatches, missing/partial data, transient failures, unsupported grammars, explicit empty syntax and an in-flight scope change. Independent review confirmed the producer seam and identified the reader-motion ownership boundary for the next consumer slice.

The existing function/type verbs now share one reader-owned motion path. A ticket is captured before scheduling, and source, displayed context, payload generation, server epoch and git-domain version are checked before syntax, after syntax and after reading hidden context. Leaving and returning to a cursor, focus, mode, page, scope or source does not revive the request; a newer lookup keeps its own presentation. Esc and task cancellation revoke the motion while immutable background observations may still cache. Producer errors can no longer replace newer feedback.

Hidden context is prepared without changing the layout. The opaque prepared value derives its source from the page and can apply only to that displayed context. The motion validates its reader, then synchronously unfolds and resolves the destination by source key. Starting on the gap being replaced therefore works without confusing the motion's own unfolding with an intervening reader move. Generic range reveals now read the range's end object rather than passing an entire `from..to` expression as a file tree.

The final independent pass found an older source-position bug retained during extraction: a trailing removal with no later new-side display row became line zero. Previous-function could refuse, while next-function jumped backward. Removed-row motion now uses its own hunk's insertion boundary, and shared changed-line anchors use the hunk header when a zero-context deletion has no surviving new line. Ordinary-context and `+N,0` EOF regressions preserve the direction of both keys.

An adjacent one-line function exposed the remaining distinction: a real line N excludes itself from previous/next, while the boundary before line N includes N for next and N−1 for previous. `ReviewSyntax.Origin` now represents those states separately for code, headers, gaps and deletions. Unknown noncode origins cannot invent line zero. Regressions cover the exact adjacency case in addition to EOF. The final independent pass found no material gap in the request fences, prepared-context handoff or origin model.

## Round 14: verification artifacts need an honest source and completed output

The offscreen renderer swallowed PNG write failures and printed success paths into a directory it never created. CapturePlan now validates the whole plan before constructing the app: known routes, preserved review scope, nonconflicting scope queries, finite waits and dimensions, one-component names and filesystem-safe duplicate identities. CLI parse failures survive into validation. CaptureOutput creates its directory, throws on allocation/encoding/write failure, and returns a path only after an atomic write. The shared boundary passed 718 tests before the consumer.

The independent effect audit changed the source design. A GET is not a sufficient read-only contract in this producer. Gates progress stamps verdicts; review flags harvest git configuration; evidence can start a job; integration node reads rebuild refs. More fundamentally, state hydration and event subscription can release previously queued replies to GitHub. Capture therefore requires `--shoot-fixture <directory>` and never discovers or connects to a live server. Conflicting headless modes and orphaned capture arguments are rejected before dispatch; `--bench` cannot bypass this boundary when combined with capture flags. Live-source capture waits for a separate producer snapshot-only contract.

The fixture directory contains bounded regular `state.json` and optional `responses.json` files. Both freeze before app construction. The snapshot supplies bootstrap repositories and a locally generated, fixture-labeled hello whose stream stays open until cancellation. The transport intercepts every request, including unknown hosts and endpoints, with no network fallback. Additional responses match method, full decoded path, the complete query and semantic JSON request body. Duplicate definitions, invalid status/body combinations and reserved readiness-route overrides fail preflight. Explicit null and explicit error responses remain distinct from missing input.

An absent read fixture is recorded and prevents the next artifact write. An explicitly modeled error can still render its error state. Operational writes receive local refusals rather than synthetic success. Runner's session refusal executes before routing, jump recording, local callbacks, asynchronous tasks or write construction; capture uses it to fence writes and editor commands. Browser/Show openers refuse, the global clipboard is private, and drafts, tutor sessions and keytutor progress retain reads while writes remain in memory. Capture disables persistent logging before app initialization. The existing bench summary reader may use a temporary frozen scenario and a read-only status subprocess; it does not run a scenario or change recorded history.

Hydration and the fixture hello must both complete before creating the root view or any image. Success paths report completed PNGs; a later failure preserves already completed artifacts and exits unsuccessfully. Missing-fixture diagnostics identify the expected request instead of substituting an empty successful payload. Offscreen CLI checks exercise directory creation, editor/write refusals, invalid plans, conflicting modes, missing input and output failures without a capture server.

## Round 15: history failure and pending choices belong to an accepted read

The history loader used one window-wide `(key, rows)` slot, with no in-flight entry. Repeated requests could overlap; a late branch A result could evict a newer branch B result; a failed read remained indistinguishable from loading. The new BranchHistory reader keeps at most 64 branch entries and qualifies each by observed branch metadata, server epoch, git/remote versions and hydration generation. Loads coalesce, failure remains terminal until an explicit retry or new source, and empty success stays ready. Request stamps and cancellation fence retries, imported results and evictions. Getters synchronously withhold stale entries. A read may populate its own branch after a reader leaves without moving the active UI. The independently reviewed shared reader passed 735 tests before consumers.

ShipState delegates to that reader. The header's load task follows the observed source, failure displays a concrete retry command, and existing line/commit motions report the actual read state. `:review.commits.retry` is available only for a failed current branch. The retired `history.*` tab namespace remains absent. Supplied history is installed only while its branch metadata still matches.

The independent consumer pass found that the pending first endpoint was an index into a changing line. If a parent advances past c1, a choice at c2 can silently become c3 at the same index. The stored endpoint now contains the accepted ready-result stamp and semantic point key; it is resolved only against that same accepted read. Replacing a read, including at the same source, revokes the old choice. The final pass found a second boundary: the default-stretch A→B→A visit could retain A's cached stamp without calling stretchMoved. Branch reset now clears the pending endpoint explicitly; the regression proves the cache survives while the choice does not.

This is an observed-source fence. The current `/commits` producer reads mutable branch, parent/dependency and configured upstream refs, returns abbreviated rows without a revision envelope, and caps the whole log at 80 rows. Native cannot certify unreported source changes or complete own-history coverage from that response. Those source/coverage requirements are tracked separately; this slice makes no immutable-history or completeness claim.

## Round 16: a delayed words action retains its reader and accepted target

Named title, why, reword and fold actions could wait for an outline and then open or save after their reader had left. Every named action, including immediate description edits, now advances one intent generation. A deferred action retains the observed branch source and reader; Esc uses the existing overlay closer to revoke only its owned intent. Background data may still arrive without reviving the action or replacing newer feedback. The shared BranchSource value was extracted from history without changing its fields and passed the full 739-test gate before this consumer.

Words reads coalesce by observed source and carry a request generation. Success requires the exact branch and full head named by that source. A replaced or canceled request cannot drain a newer request's waiters; an old failure cannot speak for a later action. A trusted imported outline explicitly retires pending requests and waiters. The view's load identity follows the observed source rather than just the branch tip. This does not turn the producer into an immutable source contract or redesign every words cache consumer.

Both commit pickers retain the accepted outline and candidate identities, capture the reader after opening, and accept only that picker's next close. They validate the reader, source, unchanged outline and index before inserting, selecting or posting. A replay after navigation, outline replacement or source movement has no effect. Typed prefixes must identify exactly one commit; an ambiguous prefix cannot silently choose the first match. Existing command names and keys remain intact.

Held-response tests cover current completion, newer immediate intent, Esc, reader A→B→A, replacement pickers, obsolete failure, mismatched branch/head/source, picker replay and ambiguous typed prefixes. The old cold-outline fixture supplied an abbreviated head and was corrected to the actual full source. The independent pass found no remaining material gap in this deferred-action boundary. The re-scan confirmed a separate whole-map rollback bug in save/undo, tracked for the next round.

The real Esc regression exposed two page-level overrides of the global closer: Review's back command and the focused branch-line cancel command. Both now consult the same owned WordsByName.backOut adapter before changing page state. With a picked line endpoint and a held outline request, the first Esc cancels the words action, the response cannot post, and the second Esc drops the endpoint. The final full gate passes 747 tests.

## Round 17: recovery owns submitted fields, and observations retire optimism

A refused words save restored whole draft and saved-text dictionaries. A late failure for branch A could erase a new draft on B or a newer edit on A. OwnedValues now stages per-key receipt nodes, including nil-valued clears. Ordinary edits revoke ownership by identity, so an equal-value round trip cannot revive an old receipt. Rollback changes only the head it still owns and traverses failed predecessors; acceptance keeps newer heads intact. Canonical reply replacements update hidden predecessor values too. Receipt instances cannot cross stores. The shared model passed 753 tests, then its reply/observation extension passed 756 before consumers. Tests enumerate all eight outcome masks and all six reply orders for three writes.

The independent re-scan found that branch ownership alone is insufficient: the producer writes PR title and body independently. If A saves a body, B later saves only a title, A fails and B succeeds, accepting a whole saved pair would falsely keep A's body; clearing a whole PR draft would also lose that unsent body. Commit drafts remain message pairs because each submitted edit includes both components. PR drafts and saved overrides have separate title/body keys. Save stages only fields actually submitted, and both public maps are now read-only projections over the owned stores.

A second interleaving sharpened explicit intent. With body B1 still unaccepted, editing B2 and then returning to B1 must keep B1 if the first request fails. An explicit edit therefore retains its literal part even when it equals a pending on-file override. Pending counts still compare effective text. A qualified outline response can retire a satisfied explicit part only through a snapshot captured synchronously at read creation, matching that part's normalized text and unchanged identity. Newer edits, equal-value round trips and other branches survive. The same observation boundary retires only previously accepted, unchanged saved overrides; a snapshot captured while a field is pending can never retire it later.

Undo no longer predicts a previous whole PR pair. It retains the original acknowledgement's actual changed field names, keeps the currently displayed overrides while sending, then retires only its own acknowledged override nodes and rereads the actual outline. This respects the producer's conditional per-field restoration. A newer save can keep its displayed value while a successful older undo updates the hidden fallback; if that newer save fails, pre-undo optimism cannot reappear. A refused undo rolls back only its own nodes. Successful no-op saves create no inverse or undo hint, and an undo restoring no fields or commits says it kept newer words while rereading. A final cross-store interleaving required one more boundary: a refresh may see restored text while an undo acknowledgement is still pending. Explicit-draft satisfaction requires no pending saved owner (including a nil-valued owner), agreement with both the returned and effective saved baseline, and the captured draft identity. Neither equal text nor a raw response can retire user intent beneath a protected override. The additive pending-owner seam passed a separate full gate before this consumer. The final full gate passes 769 tests, including that held refresh, a deferred real Runner refusal and concurrent save/undo regressions. No live write was exercised.

The producer still chooses the latest undoable journal entry by branch; it accepts no expected journal identity. Another writer can therefore change the meaning of an older native inverse before dispatch. Atomic journal pinning is a separate server contract, recorded in the tracker, rather than a guarantee this native receipt model can supply. Write acknowledgement epochs and immutable outline provenance likewise remain producer work.

## Round 18: rename choices retain their original reader and full head

Rename's name picker and confirmation retained callbacks without retaining the source or reader that offered them. Reopening a choice after A→B→A could construct a fresh request for an old body. Each intent now captures the observed BranchSource and the reader after its picker opens. It accepts only that picker's next close. Preview and apply responses retain the original request and source; another lookup or observed source change revokes them. A preview must name the exact full head, provide a nonempty diff, and identify distinct normalized relative paths with positive edit counts whose sum does not overflow. Rename is unavailable while its displayed diff is being replaced.

Held-response and replay tests cover old initial choices, confirmation choices, reader round trips, observed source changes, mismatched full heads and malformed file manifests. The independent pass found no additional ownership gap in this slice. This is a source fence, not a complete rename write boundary. The legacy Enter confirmation still sends outside Runner, and the producer recomputes edits at apply time without an immutable preview identity. Its checked-out worktree landing also checks the expected head before a later reset rather than enforcing an atomic expected-head landing. Those remain separate, tracked boundaries; native source checks cannot supply their guarantees.

## Round 19: a rename preview cannot authorize a different edit

The producer recomputes the workspace edit when asked to apply a rename. Its head guard does not bind that new answer to the diff the reader accepted, and its worktree landing is not an atomic compare-and-swap. Native cannot repair either boundary with another confirmation. The shared rename verb now describes a preview, in its own separately gated commit. The native consumer removes the apply path and confirmation picker entirely; its request type can encode only apply:false. Enter opens the validated diff and never arms or posts a rename mutation. The result names its repository, branch and observed head, reports edit/file counts and says to edit in Helix. Command discovery, tutorial and navigation policy describe the same behavior.

The actual space-r and Enter path is tested through the registry, including repeated Enter and an old picker replay. Original-reader/source fences and manifest validation remain in place. Automatic rename commits remain producer work: immutable preview identity, exact prepared edits, atomic expected-head landing and defined retry/idempotency behavior must precede a registered Runner write. No server or Show source was changed.

## Round 20: a completed lookup leaves waiting, and cancellation retires the whole lookup

A nil transport answer meant both failure and obsolete work. Current HTTP, network and decoding failures therefore left their wait forever. The shared asking loop now validates its ticket before sending and after every await, and publishes a terminal retry note only for a current failure. A ticket first proves it is the active generation before cancellation, reader or source rejection may dismiss anything. An old canceled task cannot clear a newer lookup. An already canceled asynchronous symbol-list call cannot create a fresh intent.

The member-definition fallback previously retained the first whole-module answer if its second ask failed or was canceled. Its actual member response is now authoritative: absence exits, refusal keeps its reason, and an empty answer says no definition. Cancellation clears only its owned wait and never opens that earlier module. Rename tickets carry their observed BranchSource inside the retry loop, so a source change stops further polling and loading presentation rather than waiting for a final answer to recheck.

Regressions exercise every lookup consumer under HTTP and malformed replies, retry after failure, network failure, obsolete failure beside a newer type or picker, cancellation before send and during loading, direct cancellation of a held member fallback, member refusal/empty answers, old cancellation beside newer success, and source movement during rename retry. All transport paths use local stubs.

## Round 21: an external open retains its reader, repository and coordinates

The GitHub line opener scheduled origin resolution without a reader ticket. A late response could open a browser or publish an error after the reader left. ReviewGitHubOpening now captures the reader, observed BranchSource, configured trunk name and exact ref/path/line target before scheduling. A newer handoff cancels and supersedes the older one. It checks ownership before resolution and after its await, keeps obsolete errors silent, and clears pending before invoking the replaceable external-open seam. Review's existing Escape command cancels a current pending handoff.

Wrapping the old resolver was insufficient: its checkout cache used branch and head without repository, then cached the borrowed origin under the new repo. Origin resolution now uses an explicitly targeted checkout response, requires its exact full expected head, and bypasses both legacy caches. The existing practice/test origin seam remains available, with an additional replaceable local origin reader for resolver tests. This retains the producer's checkout-preparation behavior; it does not turn /review-helix into a read-only endpoint. A dedicated origin-read contract remains producer work.

Scoped diff coordinates retain their displayed end object instead of linking those lines on today's branch. Whole-branch opens retain their existing branch-name behavior; an open file retains its pinned commit. The main key uses Repo.main, including repositories whose trunk is called master. Unready and integration diffs cannot manufacture a link to code with no known GitHub object. Tests use held local continuations and stubbed checkout replies for reader/source round trips, obsolete success and failure, Escape, newer handoffs, configured trunk, historical scope, wrong or missing head replies and cross-repository checkout-cache collisions. Every external open is captured by a test seam.

## Round 22: queued writes validate at the send boundary

A write constructor runs before Runner waits for its FIFO predecessor. A source or server-epoch guard there can expire while the queued write waits. Write now offers an optional refusal check that Runner executes after the predecessor finishes and immediately before transport posting. A local refusal follows the ordinary failed-write path: rollback, one answered callback, no inverse, no HTTP request. Existing constructors and unvalidated writes retain their behavior. Immediate and independent writes use the same check. This is an additive shared boundary, gated separately before its editor consumer. It cannot provide an atomic producer-side epoch or expected-head guarantee across the network.


## Round 23: an editor owns its checkout, quit and return destination

Helix preparation read its repository and tip inside a deferred task and matched replies only by path. Quit later re-resolved the current page's branch and repository. A retained A editor could therefore send its directory and edits toward B, including equal-head forks. Every editor now mints a session identity and freezes the observed source before scheduling. Explicit preparation requires that session, reader and source before and after its await, an exact full head, and an absolute checkout path. Stale success or failure cannot install or remove a newer same-path editor. Escape and branch changes cancel only pending preparation. Automatic checkout warming and the cache missing repository identity are removed; opening Helix is an explicit action.

A ready editor retains its original owner through navigation. Its visible header names that repository, branch and head. Native terminal identity and moved/quit callbacks carry the same session token, so an old terminal cannot move or quit a newer one. A successful process exit consumes only its session; an abnormal exit preserves the checkout without committing. The registered global gitWrite command consumes a one-use landing permit and posts the frozen repository, branch, full expected head and directory through Runner. It rechecks the observed server epoch and branch tip at the shared send boundary, after queued predecessors. There is no automatic mutation retry. Restoring the reader happens before the cursor-neutral Write constructor; all reply feedback is explicitly owned and Runner's unconditional lines are silenced.

The independent pass found that guarding feedback did not guard pending placement. A stale return survived a moved reader and was later consumed by diff refresh. HelixReturn now retains monotonic visit, focus, cursor, word, tab, mode and picker revisions separately from content replacement. It needs an explicit successful acknowledgement with an exact full new object. Matching failure, no-op or malformed acknowledgement retires only its own return before feedback checks. A partial 2xx reply cannot claim a commit or a no-op. A diff destination waits for that acknowledged current tip and payload; a file outside the old diff updates only its still-owned window to that object. Switching files inside Helix defers the new file load until the acknowledged object, so an old-file response cannot revoke the return by moving its cursor. Newer movement, an equal-position round trip or a newer editor cannot be overwritten. Historical, foreign pinned-file and unready coordinates cannot be used to edit today's checkout.

The producer still returns a shared branch checkout rather than a per-session lease, and checks detachedness without proving the requested repository/branch owns that directory. Concurrent clients can change a shared checkout; worktree landing still needs atomic expected-head enforcement. The GitHub origin resolver also retains legacy checkout preparation. Immutable checkout leases, source-bound directory validation, a read-only origin endpoint and producer-side epoch/landing guards remain separate tracked work. These native changes make no stronger guarantee about those producer boundaries.

## Round 24: work needs a visible status, update date and latest direction

The tracker already carried state, ownership and updated dates, but most of those facts disappeared from the rows. Home now has a keyboard pane for all items marked in progress. Rows retain the reported assignment and exact tracker update day. Forests and branches derive context only from their explicitly linked todo records, including the repository in the project ID and the complete solving branch name. Missing context is stated on the detail page. Nothing here claims a live worker or a code-edit timestamp.

The latest chat instruction is a separate attributed first section of the existing todo body, with a recording timestamp, source and literal blockquote. Phil chose Forests and branches as the primary surface and chat instructions as the input source. Agent progress, completion and newer review notes do not replace it. The reader never promotes arbitrary why/progress text into the user's voice. Chat input is ordered by its own timestamp across both open and completed items; ordinary tracker updates are independent. Legacy, review and malformed bodies keep their full notes without invented chat attribution. WORK-CONTEXT.md defines the recording workflow and the still-separate automatic chat-host integration.

The independent pass found that a surviving input on a completed item had no readable destination. The named todo.show path now reveals only that completed record through the same projection used for row navigation and rendering, without changing its state or the open count. Every compact preview also has an exact source action. Its SwiftUI identity includes the subject and item, so a fresh label picker cannot retain an old source after an equal-geometry update.

A conditional pane also exposed latent focus: removing the last doing item could fall back to main and later jump back when work reappeared. A focused work pane now remains visible with an honest empty/filtered state until the user leaves. The same item projection controls its pane rows and visible contents. Completion/rollback and ready-filter round trips cannot steal focus back from main. Full source input, absent dates, malformed attribution, cross-repository scope and key paths are encoded in the native tests; visual checks replay frozen local fixtures only.

## Round 25: freshness belongs to the message and execution protocol

Phil asked how to ensure the AI uses this approach without leaving stale messages. The native slice proves what a recorded section says, not that every instruction was captured or supplied to a worker. Another rule in an agent guide cannot enforce either guarantee. This round proposes the producer/runtime contract; it implements no host or server changes.

### Principles and current enforcers

| Principle | Current enforcer and strength | Verified source |
| --- | --- | --- |
| 1. The host durably captures a work-bound human message before accepting it for delivery | **Convention only.** Agents record input; session hooks record presence | `WORK-CONTEXT.md:24`, `.claude/settings.json:39`, `scripts/claude-session-track:145` |
| 2. Messages retain source identity and explicit work bindings through retries and task switches | One native path filters existing links; source IDs, binding generations and work incarnations are absent | `Sources/CanopyUI/Pages/Todo/WorkContext.swift:62`, `scripts/srv/todo.py:30` |
| 3. Input history survives progress, summaries and completion | **Convention only.** Writers replace the same body | `WORK-CONTEXT.md:26`, `scripts/srv/todo.py:142` |
| 4. Work revisions order captured knowledge; source order determines message chronology | **Unenforced.** Latest input uses its recording wall clock | `Sources/CanopyUI/Pages/Todo/WorkContext.swift:74` |
| 5. Each turn receives accumulated context and a runtime-owned revision receipt | **Unenforced.** No instruction delivery protocol | `scripts/show-app/Thread.swift:85`, `scripts/srv/todo.py:30` |
| 6. New direction makes an older completion historical rather than current | **Unenforced.** Completion has no expected instruction revision | `scripts/srv/todo.py:142`, `scripts/srv/todo.py:183` |
| 7. Assignment, liveness, reported progress and delivery remain separate observations | One native projection preserves existing distinctions; delivery and lifecycle contracts are absent | `WORK-CONTEXT.md:5` |
| 8. Freshness claims require known source coverage | Missing records are explicit; per-source capture coverage is absent | `WORK-CONTEXT.md:26` |

### Findings and proposed enforcers

**Confirmed: progress can erase newer input.** A progress writer reads body A; capture records B; progress then writes its saved body A. `todo.update` reads and replaces the whole record without an expected revision. Atomic replacement protects bytes, not this lost update. Show's `Thread.swift:22` also rewrites a shared document without message identity. Give human messages one canonical transactional store, preferably SQLite, with unique source/conversation/message IDs, immutable text and typed authors. Keep todo metadata separate; Markdown becomes a projection. Append capture, its frozen work binding, the new work revision and pending delivery in one transaction. A durable outbox retries the same message identity after a crash; duplicates do not advance the revision. An owned submission that cannot persist retains the draft and reports failure. Unowned host ingress cannot receive this guarantee.

**Confirmed: recording time does not establish instruction order.** A delayed older message can have the newest recording time and displace current direction. Retain source sequence, source time and received time separately. The coordinator assigns work revisions for concurrency checks, not human chronology. A newly discovered older message can change the context revision without becoming the latest literal message. A source adapter provides ordering and coverage cursors; gaps stay visible. Multiple conversations have no invented total human order, and conflicting direction requires a visible decision. Use stable work IDs, never reused after deletion, with branch links as metadata. Freeze a message's explicit binding when submitted; retry after a task switch cannot retarget it. Establish the binding when launching or switching work, rather than requiring a tag on every message. Ambiguous targets remain unassigned instead of being guessed from cwd, title, branch or activity.

**Confirmed: visible input does not qualify a worker's result.** Completion currently accepts `state=done` without an instruction version. At every managed start, resume and turn boundary, the runtime supplies the goal, retained constraints, ordered messages and work revision. Compaction reloads through the same boundary. The latest literal message is separate from this accumulated packet: “also show last touch” cannot erase an earlier compatibility constraint. A generated brief keeps source-message IDs and remains derived agent text; it has no authority to silently supersede user direction.

The runtime issues the delivery receipt at its actual turn-submission boundary; a prepared packet alone is not delivery, and an unacknowledged submission retains that uncertainty. The model cannot certify delivery merely by echoing a revision. Progress and completion name the attempt generation and the revision actually delivered. The coordinator checks those against current direction in the same transaction that records the result. Revision 42 arriving while 41 runs leaves 41's output readable but unable to complete 42. Direction arriving after a valid completion likewise preserves that completion in history and makes current work pending. At the next supported safe boundary, interrupt or finish the old turn and deliver the new packet before accepting a current completion. Unmanaged file edits cannot be prevented by a revision check; their provenance remains unknown.

Every caller that can claim current completion must pass that coordinator boundary, including the CLI and server routes. The journal owns qualified completion; a todo display of that fact is only a projection. A legacy `state=done` file edit remains a reported completion with unknown instruction basis and cannot bypass the check or earn a current-completion verdict. Migration must not introduce two authorities for the same fact.

The independent pass confirmed these three gaps and the native projection's existing exact linkage and attribution. Re-scanning with the delivery rule covers multiple workers, resumed sessions and inherited subtasks: each attempt retains its generation and delivered revision. A turn spanning several work items needs each item's revision in its receipt. A heartbeat proves recent contact only; dated progress reports and artifact changes retain their own sources. Delivery proves that the runtime supplied the packet, not that the model understood or obeyed it. Tests and review still assess the substance.

Show already saves a reply before scheduling delivery (`scripts/show-app/Decks.swift:562` and `:578`), which is a sound starting boundary. Pending delivery is memory-only (`scripts/show-app/Thread.swift:75`); a crash after saving still needs outbox recovery. The presence hook is deliberately warn-only and cannot enforce capture. Legacy or disconnected adapters must show capture coverage as unknown, rather than infer freshness from a quiet or recent timestamp. Old instructions can remain valid indefinitely.

### Proposed encoding order

1. `record-work-input`: canonical identities, immutable messages, frozen bindings, source coverage, transactional revisions and outbox.
2. `deliver-work-context`: one owned host adapter, automatic context delivery, runtime receipts, attempt generations and atomic completion checks. Other hosts remain explicitly unsupported until adapted.
3. `show-work-freshness`: native projections for current direction, delivered revision, dated progress, interrupted workers and unavailable capture. Existing Markdown records remain legacy imports with unknown delivery; message IDs and original times are never fabricated.

Tests ride each branch: concurrent input/progress and input/completion; crash between capture and dispatch; duplicate delivery and receipt replay; delayed older messages; source gaps; task switches before retry; branch rename and deletion/recreation; multiple workers/items; compaction/resume; legacy callers; source disconnection; and unrelated conversation exclusion. Indexed current-revision reads and paged history avoid scanning the whole conversation on each write. No measured growth threshold is available yet.

The native-only boundary still applies. These are proposals for separate producer and host work, not guarantees supplied by the current UI or agent instructions.
