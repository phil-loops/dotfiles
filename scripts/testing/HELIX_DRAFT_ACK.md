# Acknowledged Helix saves

This isolated candidate makes a real Helix save wait for a durable accepted draft. It is one file,
one owned writer, UTF-8 without a BOM, and disposable projections only. It publishes no Git refs
and changes no production Canopy route or installed editor.

`helix-draft-save.patch` applies to Helix revision
`14d6bc0febed9c692048271a8ae2362ac969c6e0`. It adds the experimental LSP request
`canopy/draft/acceptSave`. A companion advertises one URI, generation and initial draft revision;
the candidate's required mode refuses missing bridges, changed destinations and unsupported
encoding before writing.

Helix clones the post-formatter text before file I/O. After the ordinary file write, it submits
that immutable payload and waits for a receipt matching its generation, operation, accepted
revision, text and mode. Only then does it mark that captured buffer revision saved. Newer
buffer edits remain dirty. A failed acknowledgement remembers the editor's own physical-write
timestamp without marking its draft saved, allowing safe retry while retaining external-write checks.

The pending request survives a timeout within the client. A later save replays the original
payload before submitting its causal successor. Unchanged saves also re-contact the lease holder;
an in-memory success does not bypass ownership checks. SQLite WAL/FULL retains immutable accepted
versions and exact replay responses. Generation checks precede replay. An inherited kernel lease
keeps the projection owned by the actual editor even if the companion dies.

## Run

Apply the patch only in a separate checkout at the pinned revision, then build that candidate:

```sh
git -C /path/to/disposable/helix apply /path/to/dotfiles/scripts/testing/helix-draft-save.patch
HELIX_DISABLE_AUTO_GRAMMAR_BUILD=1 cargo build --locked --no-default-features -p helix-term
```

The build command runs from the Helix checkout. The test build omits Git support and reuses an
existing runtime; it is not a replacement editor distribution. Use the machine's `heavy-turn`
queue for compilation. A normal candidate without a bridge retains ordinary save behavior;
the probe explicitly requires the bridge through its launch environment.

From the dotfiles root:

```sh
python3 -W error::ResourceWarning scripts/testing/test_helix_save_journal.py
python3 scripts/testing/probe_helix_draft_ack.py \
  --binary /path/to/disposable/helix/target/debug/hx \
  --runtime /path/to/existing/helix/runtime \
  --output /private/tmp/new-draft-ack-run
```

Use a fresh output directory. The probe creates isolated config/cache directories and its own
PTY. It never drives a user's terminal or trusts a project-local configuration. `--show-job`
optionally reports the check count to an existing Show job.

The patch includes two focused Rust tests; run `cargo test --locked --no-default-features
-p helix-lsp -p helix-view draft_save` from the candidate source.

## Evidence and remaining work

Ten journal tests cover exact replay/restart, changed payload/mode, stale scans, immutable history,
owner transfer, editor-held leases, journal replacement, copied projection refusal, and SIGKILL
before/after atomic acceptance. Two Rust tests check exact receipt identity and snapshot capture
before I/O while later edits stay dirty. Ten actual-editor scenarios cover held `:w`/`:wq`,
lost response with newer edits, stale acknowledgements, corrupt receipts, missing bridges, changed
destinations, failed file writes, a companion kill between replay and successor acceptance,
and a refused acknowledgement keeping an unchanged buffer dirty.
The stock installed editor fails the required-acceptance scenario: it writes the file without
asking the journal to accept it.

Automatic interrupted-session reconciliation is deliberately absent. An ambiguous disk/journal
pair is preserved and refuses readiness until explicit recovery. This is a bounded failure state,
not an automatic retry loop or permission to overwrite either copy. A successful journal save
does not mean formatted successfully, published, synchronized to another checkout or painted.

Multi-file membership, arbitrary external writers, filters/other encodings, complete restart
recovery, native Canopy wiring and publication remain separate acceptance gates. The original
scan/reconciliation path and forest/history safeguards remain required. Physical power-loss
durability is not established by process-kill tests.
