# Offscreen captures

`--shoot` renders the native app without a visible window. It requires local fixtures and never connects to a server. Live `/state` and event subscription can release queued replies; they cannot supply a read-only capture source.

```sh
swift build --product Canopy
.build/debug/Canopy --shoot /tmp/canopy-images \
  --shoot-fixture /path/to/fixture \
  --shot 'review=/v2/b/loops/feature =? !keys esc' \
  --size 1280x800 --dump-wait 1
```

The launcher accepts the same flags and skips port discovery for captures. Capture flags cannot be combined with `--bench` or `--dump`.

The fixture directory requires a valid `state.json` snapshot, including `epoch`, `versions` and `entities`. Use canned data or an existing authorized recording. Capturing does not fetch a recording from a live server. Each fixture file must be a regular file at most 8 MiB. Files freeze before the app starts. Bootstrap repositories and a persistent local hello stream come from that snapshot.

An optional `responses.json` array supplies additional page data. Entries match the method, decoded path, complete query and semantic JSON request body:

```json
[
  {
    "method": "GET",
    "path": "/loops/node",
    "query": {"branch": "feature"},
    "body": {"branch": "feature", "baseSha": "abc1234", "files": []}
  },
  {
    "method": "POST",
    "path": "/loops/syntax/units",
    "request": {"sha": "def5678", "path": "models/message.ts"},
    "status": 503,
    "body": {"ok": false, "err": "recorded unavailable source"}
  }
]
```

Each response has exactly one of `body` (JSON, including explicit null) or `text` (plain text). `status` defaults to 200. Query ordering and JSON object ordering do not matter; omitted values, extra values, duplicate query names and different request bodies do. Duplicate definitions and overrides of `/state`, `/v2`, `/events` or `/v2/events` are rejected.

GETs and the existing read-only syntax/LSP asks can use recorded responses. Operational writes are refused even if a fixture claims success. Every request is intercepted; unknown hosts, endpoints and unmatched reads have no network fallback. Missing input is printed to stderr and prevents the next image write. Explicit error responses are valid inputs for rendering error states.

After the route, tokens press keys through the normal engine. `=?` presses the question-mark key; bare `?` prints cursor diagnostics. `~0.5` waits, `!name` writes an intermediate image, and `#` reports that terminal input is unavailable. `>text` is rejected. Names must be unique filename components, including case-equivalent names. Waits must be finite and between 0 and 60 seconds.

Capture refuses editor commands, server writes and external application opens. Clipboard, draft writes, tutor session writes and keytutor progress stay private to the process; persistent logging is disabled. Local bench/job documents and current key files can still be read. Bench status may use temporary files and a read-only subprocess; capture does not run bench scenarios.

A printed PNG path means encoding and atomic writing completed. Exit 0 means every requested artifact completed with no observed missing fixture input. Exit 1 means initial readiness failed; exit 2 means capture validation, missing input or artifact creation failed; CLI usage errors exit 64. A later failure leaves earlier completed images intact.

`--bench` and `--dump` retain their existing live-source behavior. Their producer needs a snapshot-only contract before those modes can certify a read-only source collection.
