---
title: Time partitioning
section: Stores
order: 23
ask: packages/mail-pg/src/seed-partitions.ts
lede: Postgres — why every mail table is PARTITION BY RANGE.
---

All three mail tables are partitioned by time — [[enqueued-email]] by `enqueued_at`, [[status-log]] by `at`, [[packed-artifact]] by `rendered_at`.

Mail tables are append-heavy and worthless after a while, which makes retention the whole design problem. Partitioning by time turns it into `DROP TABLE` on an old partition: instant, no vacuum storm. The alternative — a big `DELETE` — would churn the indexes on the *hot* partition, which is exactly the one serving live traffic.

The practical catch is that a partitioned table needs its partitions to **exist before** rows land in that range. Nothing creates them lazily on insert, so the package ships [a seeder](src:packages/mail-pg/src/seed-partitions.ts#main) that has to have run ahead of time. If it hasn't, inserts fail outright rather than degrading.
