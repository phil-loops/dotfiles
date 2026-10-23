#!/usr/bin/env python3
"""test-lsp-service.py — the type service's pure decisions (srv/lsp.py), no tsgo, no repo.
The end-to-end check against fresh references is test-lsp-differential."""
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
os.environ.setdefault("STACK_LSP_STATE_DIR", tempfile.mkdtemp())
from srv import lsp  # noqa: E402

fails = 0


def check(name, got, want):
    global fails
    if got != want:
        fails += 1
        print(f"✗ {name}: got {got!r}, want {want!r}")
    else:
        print(f"✓ {name}")


inputs = ["trpc/root.ts", "lib/zod/team.ts", "models/team.ts", "lib/x/index.ts", "lib/mergetagmanipulation.ts"]
check("unknown inputs always regenerate", lsp.needs_regen([("M", "README.md")], None), True)
check("an input file changed", lsp.needs_regen([("M", "models/team.ts")], inputs), True)
check("an input recorded lowercased", lsp.needs_regen([("M", "lib/mergeTagManipulation.ts")], inputs), True)
check("a file outside the graph changed", lsp.needs_regen([("M", "components/Button.tsx")], inputs), False)
check("a test beside an input", lsp.needs_regen([("M", "models/team.test.ts")], inputs), False)
check("a manifest", lsp.needs_regen([("M", "apps/x/package.json")], inputs), True)
check("a tsconfig", lsp.needs_regen([("M", "typescript/tsconfig.trpc-types.json")], inputs), True)
check("packages source", lsp.needs_regen([("M", "packages/valkey/src/index.ts")], inputs), True)
check("a prisma migration only", lsp.needs_regen([("A", "packages/prisma/migrations/1/migration.sql")], inputs), False)
check("an added file shadowing an input stem", lsp.needs_regen([("A", "models/team.tsx")], inputs), True)
check("an added declaration beside an input", lsp.needs_regen([("A", "models/team.d.ts")], inputs), True)
check("an added index for an input stem dir", lsp.needs_regen([("A", "lib/zod/team/index.ts")], inputs), True)
check("an added unrelated file", lsp.needs_regen([("A", "models/brand-new.ts")], inputs), False)
check("a deleted non-input", lsp.needs_regen([("D", "components/Old.tsx")], inputs), False)
check("a deleted input", lsp.needs_regen([("D", "lib/zod/team.ts")], inputs), True)

f0 = {"/t/a": (1, 1, 1), "/t/b": (1, 1, 2), "/t/c": (1, 1, 3)}
f1 = {"/t/a": (1, 1, 1), "/t/b": (2, 5, 2), "/t/d": (1, 1, 4)}
ev, links = lsp.snapshot_events((f0, {"l": "x"}), (f1, {"l": "x"}))
check("snapshot events", ev, [("/t/b", lsp.CHANGED), ("/t/c", lsp.DELETED), ("/t/d", lsp.CREATED)])
check("unchanged links", links, False)
check("changed links", lsp.snapshot_events((f0, {"l": "x"}), (f0, {"l": "y"}))[1], True)

with tempfile.TemporaryDirectory() as d:
    root = os.path.realpath(d)
    os.makedirs(os.path.join(root, ".gen"))
    with open(os.path.join(root, ".gen", "trpc-types.tsbuildinfo"), "w") as f:
        json.dump({"fileNames": ["../node_modules/zod/index.d.ts", "lib.es5.d.ts", "../trpc/root.ts", "../models/Team.ts"]}, f)
    check("gen inputs are the tree's own files, case-folded", lsp.gen_inputs(root), ["models/team.ts", "trpc/root.ts"])

print("ok" if not fails else f"{fails} failed")
sys.exit(1 if fails else 0)
