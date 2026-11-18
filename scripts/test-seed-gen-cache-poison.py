#!/usr/bin/env python3
"""test-seed-gen-cache-poison — an audit that finds a poisoned entry names the files the stored
emit and the fresh build disagree on, and keeps both copies of each, before the entry is evicted."""
import importlib.machinery, importlib.util, os, sys, tempfile

SCRIPTS = os.path.dirname(os.path.realpath(__file__))
loader = importlib.machinery.SourceFileLoader("sgc", os.path.join(SCRIPTS, "seed-gen-cache"))
C = importlib.util.module_from_spec(importlib.util.spec_from_loader("sgc", loader))
loader.exec_module(C)

fails = 0
def check(name, ok):
    global fails
    fails += not ok
    print(f"  {'✓' if ok else '✗'} {name}")

def tree(root, files):
    for rel, data in files.items():
        p = os.path.join(root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(data)
    return root

with tempfile.TemporaryDirectory() as t:
    same = {"a.d.ts": "x\ny\n", "b/c.d.ts": "p\n", "m.d.ts.map": '{"version":3,"mappings":"AAA"}'}
    stored = tree(os.path.join(t, "stored"), {**same, "d.d.ts": "user?: Prisma\n", "gone.d.ts": "z\n"})
    built = tree(os.path.join(t, "built"), {
        **same, "a.d.ts": "y\nx\n", "m.d.ts.map": '{"version":3,"mappings":"BBB"}',
        "d.d.ts": "user?: Prisma.User\n", "new.d.ts": "n\n"})
    where = os.path.join(t, "poison", "k")
    differ = C.poison_evidence(stored, built, where)
    check("names exactly the files that differ canonically", differ == ["d.d.ts", "gone.d.ts", "new.d.ts"])
    check("keeps the stored copy", open(os.path.join(where, "entry", "d.d.ts")).read() == "user?: Prisma\n")
    check("keeps the built copy", open(os.path.join(where, "built", "d.d.ts")).read() == "user?: Prisma.User\n")
    check("a file on one side only is kept on that side", os.path.exists(os.path.join(where, "entry", "gone.d.ts"))
          and not os.path.exists(os.path.join(where, "built", "gone.d.ts")))
    check("line order and map mappings stay the emit's own nondeterminism",
          C.canon_files(stored)["a.d.ts"] == C.canon_files(built)["a.d.ts"])
    check("the digest agrees with the per-file view", (C.canon_digest(stored) == C.canon_digest(built)) == (differ == []))
    many = tree(os.path.join(t, "many"), {f"f{i}.d.ts": str(i) for i in range(C.POISON_KEEP + 5)})
    none = tree(os.path.join(t, "none"), {"keep.d.ts": ""})
    w2 = os.path.join(t, "poison", "many")
    d2 = C.poison_evidence(many, none, w2)
    kept = sum(len(fs) for _, _, fs in os.walk(w2))
    check("lists every difference but keeps at most POISON_KEEP pairs", len(d2) == C.POISON_KEEP + 6 and kept == C.POISON_KEEP)

sys.exit(1 if fails else 0)
