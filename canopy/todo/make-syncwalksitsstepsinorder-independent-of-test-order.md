+++
title = "Make syncWalksItsStepsInOrder independent of test order"
kind = "fix"
state = "open"
area = "review"
size = "S"
why = "it fails ~1 in 3 full native runs with 'the gates didn't start — http 404' and passes alone; a flaky gate test trains everyone to re-run"
incarnation = "i_4ee890f0e7a24d84b8b2a648df91be52"
created = "2026-11-17"
updated = "2026-11-17"
+++

Seen 2026-11-17 twice in full `swift test --package-path scripts/canopy-native --disable-sandbox --skip-update --no-parallel` runs (ShipTests.swift:741: note "the gates didn't start — http 404" instead of "synced add-hankles-limited-label"); it passes alone and on a re-run, with or without the change under test.

## Next steps
1. Find the shared state: ShipStub's answer table is keyed by port; check whether two suites reuse a port (ShipTests.nextPort is a static counter; another suite may start at the same 41000+ range) or whether a prior test leaves a `/loops/gates` answer unset for the port this test reads.
2. Give the test its own port range or stub its `/gates` answer explicitly.
3. Done when 10 consecutive full runs pass it.
