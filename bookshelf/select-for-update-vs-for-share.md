# SELECT FOR UPDATE vs FOR SHARE

**The idea.** Both lock the rows a `SELECT` returns until the transaction ends, and neither blocks a plain `SELECT`. `FOR UPDATE` is exclusive: one transaction holds the row, and everyone else who wants to lock or write it waits. `FOR SHARE` is shared: many transactions can hold it at once, and only writers wait.

## Read

- [ ] **[PostgreSQL docs: Row-Level Locks](https://www.postgresql.org/docs/current/explicit-locking.html#LOCKING-ROWS)** — section 13.3.2. Four lock modes and the conflict table (Table 13.3) that answers every "does A block B" question.
  *Question:* two transactions each take `FOR SHARE` on the same row and then both try to `UPDATE` it. What happens, and why would `FOR UPDATE` have avoided it?

## Notes

