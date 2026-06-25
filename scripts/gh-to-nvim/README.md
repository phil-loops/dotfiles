# GitHub → nvim (Chrome extension)

Routes a GitHub PR into the local forest viewer's warm nvim. Backend is the
viewer's `POST /from-github` (import the PR → optionally open a file at a line).
See `../design-github-to-nvim-extension.md` for the full design.

## Status — feature-complete (steps 1–5)

- **Floating buttons (bottom-right):** `→ nvim` imports the current PR;
  `→ viewer` imports it and opens the node in the forest viewer (new tab).
- **Per-file `nvim` button** in each diff file header — opens that file at line 1.
- **⌥-click a diff line number** (right/new side) → opens that exact file+line in
  the warm nvim. A blue outline appears on hover while ⌥ is held to advertise it.
- A toast (bottom-right) reports the file:line result of a line-click.

All paths hit the viewer's `POST /from-github`.

## Load it

1. Make sure the viewer is serving the new endpoint (restart it so `/from-github`
   is live), then smoke-test:
   ```
   curl -s localhost:62333/from-github -d '{"number":"__nope__"}'
   # → {"ok": false, "err": "no pr number"}   (400)
   ```
2. `chrome://extensions` → enable **Developer mode** → **Load unpacked** →
   pick this `gh-to-nvim/` directory.
3. Open any PR on github.com and try:
   - the `→ nvim` / `→ viewer` pills (bottom-right),
   - the `nvim` button in any file's header (opens at line 1),
   - **⌥-click** a line number on the new/right side (opens that file+line).
   After editing the extension, hit **reload** on its card in `chrome://extensions`.

## Notes

- The floating pills are fixed-position on purpose — robust to GitHub's
  virtualized React diff DOM. Per-file/line affordances live inside the diff and
  are (re)attached via a `MutationObserver` as rows mount on scroll.
- ⌥-click is the line trigger so we don't hijack GitHub's own click-to-select-line.
- Only `http://localhost:62333` is in `host_permissions`; nothing leaves the
  machine.
