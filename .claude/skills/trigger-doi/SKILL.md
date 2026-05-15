---
name: trigger-doi
description: Enable double opt-in (DOI) on the loops `default-team` and trigger the opt-in flow by creating a pending contact and running the opt-in job. Use when the user says "trigger DOI", "enable DOI and run it", "send a DOI test", "generate an opt-in contact", or wants to exercise the opt-in email path on the dev team.
---

# Trigger DOI on default-team

Enables `optInEnabledAt` on the `default-team` row in dev Postgres, then runs `scripts/generate-opt-in-contact.ts` to create a `pending` contact and fire the opt-in job. The script logs a `Sending opt-in email` line with the new `contactId` / `optInId` once the work is done.

## When to use

- "Trigger DOI" / "Send a DOI" / "Run the DOI thing" → run the full flow
- "Enable DOI on default-team" only → just step 1
- "Generate an opt-in contact" → run the full flow (the script requires DOI to be enabled, so step 1 is a precondition)

## Repo precondition

This skill is loops-specific. Verify cwd is the loops repo (`package.json` exists with `"name": "loops"`) before running. If not, stop and tell the user.

## Step 1 — Enable DOI on default-team

The Team row must have `optInEnabledAt` set or the script throws `Opt-in is not enabled for team: default-team`. Set it via psql against the docker postgres:

```bash
PGPASSWORD=password psql -h localhost -U postgres -d postgres \
  -c "UPDATE \"Team\" SET \"optInEnabledAt\" = NOW() WHERE id = 'default-team' AND \"optInEnabledAt\" IS NULL RETURNING id, \"optInEnabledAt\";"
```

The `AND "optInEnabledAt" IS NULL` clause makes this idempotent — if DOI was already enabled, the UPDATE returns 0 rows and we leave the existing timestamp alone. That preserves the original enable time, which can matter for audits/tests.

## Step 2 — Trigger the script

**Do not use `npm run opt-in`.** The npm script is broken: it omits `--import dotenv/config`, so the script tries to talk to Postgres with no password and fails with `SASL: SCRAM-SERVER-FIRST-MESSAGE: client password must be a string`.

Run it directly with dotenv loaded:

```bash
npx tsx --tsconfig tsconfig.node.json --import dotenv/config scripts/generate-opt-in-contact.ts
```

The script:

- Generates a random `phil+...@loops.com` email
- Creates a `Contact` with `subscribed: false`, `optInStatus: pending`
- Calls `optInJob` to send the opt-in email

Success looks like a single log line:

```
{"level":"info",...,"optInId":"...","contactId":"...","teamId":"default-team","msg":"Sending opt-in email"}
```

## Expected noise — ECONNREFUSED 127.0.0.1:6379

After the success log, expect a flood of `connect ECONNREFUSED 127.0.0.1:6379` errors that repeat every ~500ms forever. **Ignore them.** They're a background ioredis client retrying against a Redis the dev environment doesn't run on that port — the actual dev valkeys run on 6378/6377/6380, and the email work has already been queued via SQS / the configured client by the time the success log fires.

Because of those retries, the script never exits on its own. Run it as a background command (`run_in_background: true`) and tail the output until you see `Sending opt-in email`, then kill it:

```bash
pkill -f generate-opt-in-contact
```

Or run with a hard timeout (~10s is plenty — the success log appears in 1-3s).

## Verification

To confirm the contact landed:

```bash
PGPASSWORD=password psql -h localhost -U postgres -d postgres \
  -c "SELECT id, email, \"optInStatus\", \"createdAt\" FROM \"Contact\" WHERE \"teamId\"='default-team' AND \"optInStatus\"='pending' ORDER BY \"createdAt\" DESC LIMIT 1;"
```

The newest row should match the `contactId` from the success log and have `optInStatus = pending`.

## Reporting back

Tell the user:

- Whether DOI was already enabled or just turned on (and on what timestamp)
- The new `contactId` and email address
- Whether the success log fired

Keep it to 2-3 lines. Don't paste the ECONNREFUSED noise — it's not signal.

## If the user wants a real fix to `npm run opt-in`

The clean fix is to add `--import dotenv/config` to the `opt-in` script in `package.json` (matching how `script-runner`, `sqs-jobs:dev`, etc. are defined). This skill works around the broken script rather than fixing it — offer the fix if the user mentions hitting the password error themselves.
