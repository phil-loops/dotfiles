+++
title = "Run the bench after every canopy commit and say which key got slow"
kind = "build"
state = "done"
area = "perf"
size = "M"
why = "2dc56d4 shipped a 3s h/l on big reviews within an hour; only a manual bench run caught it"
created = "2026-11-02"
updated = "2026-11-02"
+++

A short pass (home, one forest, the biggest open review) runs against the live server when a commit touches `scripts/canopy-native/`. It takes about a minute and never blocks the commit. A key over budget arrives as a Show notification naming the key, page, ms and commit.

## Next steps
- `canopy --bench --quick`: three pages, keys + pressure passes only, one line per over-budget key, exit 1 if any.
- Run it from Show's autobuild after a build that touched canopy-native (it already knows the changed paths), and remember the last green commit.
- On red, send a Show arrival (no focus) with the bench lines and the commit range since the last green.

## Done
2026-11-02 — canopy-benchwatch (launchd com.philbrockman.canopy-benchwatch): after a commit touching canopy-native settles, builds it in its own worktree, runs canopy --bench --quick --budget 100 on canopy/bench-pages, re-runs any page that goes over, and arrives a Runs deck in Show naming the slow keys and the commits since the last green run. First run green at 397e9d6.
