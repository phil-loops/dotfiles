#!/usr/bin/env python3
"""test-test-db — a test database is named by exactly what builds it: the migrations and the seed."""
import importlib.machinery, importlib.util, os, sys, tempfile

SCRIPTS = os.path.dirname(os.path.realpath(__file__))
loader = importlib.machinery.SourceFileLoader("tdb", os.path.join(SCRIPTS, "test-db"))
T = importlib.util.module_from_spec(importlib.util.spec_from_loader("tdb", loader))
loader.exec_module(T)
fails = 0


def check(name, ok):
    global fails
    fails += not ok
    print(f"  {'✓' if ok else '✗'} {name}")


def write(tree, rel, data):
    p = os.path.join(tree, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(data)


with tempfile.TemporaryDirectory() as t:
    write(t, "packages/prisma/migrations/1_init/migration.sql", "CREATE TABLE a ();")
    write(t, "seed-prisma/seed.ts", "seed()")
    write(t, "lib/x.ts", "x")
    base = T.digest(t)
    check("the same inputs name the same database", T.digest(t) == base)
    write(t, "lib/x.ts", "y")
    check("app code outside the migrations and seed leaves the name alone", T.digest(t) == base)
    write(t, "packages/prisma/migrations/2_more/migration.sql", "ALTER TABLE a ADD b int;")
    after_migration = T.digest(t)
    check("a new migration names a new database", after_migration != base)
    write(t, "seed-prisma/seed.ts", "seed(more)")
    check("a seed change names a new database", T.digest(t) != after_migration)
    check("a name is a valid Postgres identifier", (T.PREFIX + T.digest(t)).isidentifier()
          and len(T.PREFIX + T.digest(t) + "_b99999") <= 63)

sys.exit(1 if fails else 0)
