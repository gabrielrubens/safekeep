# SafeKeep — Architecture

This is the design rationale and decision record for SafeKeep. The [README](README.md) covers what it does and how to deploy it; this doc covers **why it's shaped the way it is**.

## Goals

1. **Daily off-site, encrypted backup** of every Postgres accessory we run.
2. **Reusable across apps** — a single image consumed via env vars, no per-app forks.
3. **One keypair, one bucket** — operationally lean. One age secret to protect, one B2 dashboard to watch.
4. **Survives renames and host moves** — no host-side paths, no host-side cron, nothing tied to the FS layout of `/opt/<app>/`.
5. **Self-restorable** — a single `kamal accessory exec backup ... restore.sh latest` rebuilds the DB.
6. **Opt-in alerting that works without the app.** Failure alerts go directly from the runner, not via the app's framework — so when the app is down, alerts still fire.

## Why these choices

| Decision | Rationale |
|---|---|
| **Kamal accessory, not host cron** | Survives `/opt/<app>/` renames, `git pull`, host re-provisioning. Inherits Kamal logging + restart policy. Same model as `postgres` and `redis`. |
| **One image, many apps** | Cuts maintenance to one source tree. Each app injects its own `PG_HOST`, `BACKUP_PREFIX`, secrets. |
| **One bucket, one keypair (recommended)** | Object Lock + SSE-B2 are bucket-level. One bucket is one ops surface. Per-app prefixes (`pensio-prod/`, `gravity-prod/`, …) keep things tidy without multiplying credentials. One age keypair means one secret to safeguard. |
| **age, not GPG** | Modern, single binary, single recipient string, no keyring. The secret key is one short file. |
| **rclone, not the B2 CLI** | Single binary handles auth + path-based copy + filtered listing. Same tool we'd use for other clouds in v0.4.0 (R2 cross-cloud). |
| **Postgres N-alpine base image** | Guarantees `pg_dump` matches the server major version. Bumping Postgres = bumping this image. |
| **`/state` volume** | Local plaintext dumps (gzipped) survive container restarts; `find -mtime` prunes. Operators can `zcat` and inspect on the VPS without ever touching the age secret key. |
| **Loop, not cron-in-container** | Simpler. Failures log without killing the process. `INITIAL_DELAY` prevents thrash on restart loops. |
| **Runner sends alerts directly, not via app** | Every adopting app gets failure email out of the box without per-framework code. Alerts survive when the app itself is down. |

## The three monitoring layers (v0.1.1+)

Three independent paths, each gated on its own env var. Mix and match.

| Layer | Trigger | Env gate | What it catches |
|---|---|---|---|
| **1 — SMTP email on failure** | `STATUS=failed` | `SMTP_HOST` | `pg_dump` errors, `rclone` errors, encryption errors |
| **2 — Healthchecks.io ping on success** | `STATUS=success` | `HEALTHCHECK_URL` | Runner crashed / OOM / never reached the email code path |
| **3 — `/state/last-success.txt` sentinel** | Always (built-in) | none | External watchdog can `cat` it for last-OK timestamp |

### Why two layers, not one

| Failure scenario | Layer 1 (SMTP) | Layer 2 (HC.io) |
|---|---|---|
| `pg_dump` fails | ✅ Email arrives | ❌ no ping |
| `rclone upload` fails (B2 down) | ✅ Email arrives | ❌ no ping |
| Runner container OOM-killed | ❌ no email | ✅ HC.io alerts after grace |
| SMTP itself broken | ❌ no email | ✅ HC.io still pings on success |

Layered = each path catches what the other misses.

## What's intentionally NOT in SafeKeep

These get asked about; they're deliberately out of scope:

- **App webhooks back to the app.** An earlier design had the runner POST to an app endpoint to populate an in-app `BackupRecord` table. Dropped because B2 is the source of truth for "what files exist" and Healthchecks.io is the source of truth for "did the runner run." Mirroring that into every adopting app's database adds coupling for no new information. May revisit as a `STATUS_JSON_URL` env var if a future use case warrants it (see [ROADMAP.md](ROADMAP.md)).
- **Slack/Discord/Telegram integrations.** Use Healthchecks.io's built-in integrations — it does this better than we would.
- **Cron-style scheduling.** A single `BACKUP_INTERVAL` covers 99% of cases; if you need cron expressions, run multiple accessories with different prefixes and intervals.
- **Backup-of-backups.** Object Lock + per-version retention in B2 is the answer; we don't move data to a second cold tier from the runner. (v0.4.0 will add multi-destination simultaneous upload, which is different.)
- **In-process Postgres restore validation.** Validating a dump by restoring it requires a second Postgres instance. Planned as v0.2.0, but it's a bigger architectural change (sidecar Postgres, scratch volume) and intentionally separate from the basic backup loop.

## File layout inside the container

```
/usr/local/bin/
  entrypoint.sh    # dispatcher: loop | once | restore | shell
  backup-loop.sh   # long-running scheduler
  backup.sh        # one-shot: pg_dump → encrypt → upload → prune → mark
  restore.sh       # one-shot: fetch (local or B2) → decrypt → psql

/state/            # mounted volume
  dumps/           # local gzipped plain dumps; pruned by LOCAL_RETENTION_DAYS
  last-success.txt # ISO-8601 UTC of last successful run
```

Local plain dumps stay around so an operator can `zcat` and grep them on the VPS without needing the age secret key. Encrypted artifacts are uploaded then deleted locally — they exist only in B2.

## Why the local plain dump is fine

People sometimes flinch at "plaintext on the VPS." The reasoning:

- The plaintext is in a volume only readable by the backup container itself
- Anyone with shell on the VPS already has shell on the Postgres container next to it — they can `pg_dump` themselves
- The threat model SafeKeep defends against is **off-site exposure** (B2 leak, transit interception, decommissioned hardware) — not on-host compromise
- Setting `LOCAL_RETENTION_DAYS=0` disables local plain dumps if your threat model is different

## Naming conventions

- `BACKUP_PREFIX`: `<app>-<env>` (e.g. `pensio-prod`, `gravity-staging`). Used as both the B2 path segment AND the dump filename prefix, so it shows up in two places. Keep it short — it ends up in URLs.
- B2 layout: `b2:<bucket>/<prefix>/<prefix>-<UTC-timestamp>.sql.gz.age`
- One bucket can host many apps; the prefix keeps them separate.

## Versioning

- `vX.Y.Z` git tags trigger a GHA build that pushes `ghcr.io/gabrielrubens/safekeep:vX.Y.Z`.
- No `:latest` tag — adopters pin explicitly. Upgrades happen by editing one line in `config/deploy.yml` and running `kamal accessory reboot backup -d <env>`.
- Backwards compatibility on env var names is a hard contract — renaming `BACKUP_PREFIX` would break every adopter's B2 paths.

## Out-of-band ops

These don't need SafeKeep code changes; documenting where they live:

- **B2 lifecycle rules** — set on the bucket directly via the B2 dashboard (e.g. "keep last 60 days" as a free safety net under SafeKeep's own pruning). Defer until you've watched the runner self-prune for 30+ days.
- **Object Lock retention** — bucket-level (Compliance mode) or per-object. SafeKeep does not set per-object retention today; rely on bucket defaults.
- **Healthchecks.io account + checks** — created manually once, URLs pasted into env. Free tier (20 checks) covers many apps × envs.

## Related

- [README.md](README.md) — what it does, how to deploy
- [ROADMAP.md](ROADMAP.md) — what's next, what's deferred
