# SafeKeep — Roadmap

What's planned, what's deferred, and the open questions worth re-asking later.

## Shipped

### v0.1.3 — failed runs signal Healthchecks.io immediately (2026-08-19)
- **`<HEALTHCHECK_URL>/fail` ping on failure** — a dead run turned the check red only when its grace window expired, up to a full `BACKUP_INTERVAL` late. It now signals at once
- **Fires on ANY non-zero exit**, not only runs that got far enough to set `FAILED_STEP`. A run dying before the first step previously left no trace on either layer
- **Ping ordered before the failure email** — it is the path that does not depend on SMTP, which is exactly the failure an email alert cannot report on itself
- **Trailing slashes stripped** so a URL pasted with one does not request `//fail`
- Known cost: stopping the container mid-run reads as a failure and turns the check red. Rare, self-clearing on the next success, and silence is the worse way to be wrong

### v0.1.2 — orphaned `.age` files were immortal (2026-08-18)
- **Encrypted artifact now removed on every exit path**, not just success. Any run dying between `age` and `rclone copy` used to leave a `.age` file behind permanently
- **The local prune could never see them** — it globbed `${BACKUP_PREFIX}-*.sql.gz`, which `find -name` cannot match against `<prefix>-<stamp>.sql.gz.age`
- Either bug alone was harmless; together they leaked one file per failed run, forever, on a volume whose entire purpose is bounded retention. Six were found on Pensio's volumes dating to 2026-04-26

### v0.1.1 — alerting + standalone repo (2026-04-27)
- **Layer 1: SMTP email on failure** — opt-in via `SMTP_HOST` + `ALERT_RECIPIENTS`. Sends RFC822 email via `msmtp` with subject `[<APP_NAME>] Backup FAILED — <BACKUP_PREFIX>`, body includes which step failed, DB connection, hostname, retry interval, and last 20 lines of the failed step's stderr
- **Layer 2: Healthchecks.io ping on success** — opt-in via `HEALTHCHECK_URL`. Pings via `curl` with 5s timeout
- **EXIT-trap dispatch** — `on_exit` reads `$?` and the most recent `FAILED_STEP`/`FAILED_LOG` to route between success ping and failure email
- **Per-step stderr capture** (`mktemp` for `pg_dump`/`age`/`rclone`) so failure emails include diagnostic context
- **Helper failures don't propagate** — email or ping failure logs a warning and continues; the backup itself is the priority
- **Image additions:** `msmtp` (~150KB), `curl`
- **Source extracted from Pensio** (`pensio/tools/db-backup-runner/`) into this standalone repo earlier in the session

### v0.1.0 — initial release (2026-04-26)
- Postgres → gzip → age → B2 with retention pruning, as a Kamal accessory
- `restore.sh` for local + remote (B2) restoration
- `/state/last-success.txt` sentinel for external watchdogs
- Source originally lived in `pensio/tools/db-backup-runner/`

## Planned

### v0.2.0 — pre-upload restore validation
The "I have a backup" → "I have a *restorable* backup" jump. Spin up an ephemeral Postgres in the container (or sidecar), restore the fresh dump into it, fail loudly if it doesn't reach a known sentinel state (e.g. expected table count, a `SELECT 1 FROM <known_table> LIMIT 1`).

Open architectural questions:
- Sidecar Postgres vs in-container second instance vs ephemeral remote VPS
- Cost of the validation step (restoring N GB daily isn't free)
- Sentinel definition — universal or per-adopter via env var?

### v0.3.0 — file backups
Same loop, different "dump" step. Tar a configured directory (e.g. `/app/media`, `/app/data`) → encrypt → upload. Likely a separate `BACKUP_MODE=files` env switch with `FILE_PATHS` for paths to capture.

### v0.4.0 — multi-destination simultaneous upload
B2 + Cloudflare R2 in parallel, for cross-cloud insurance ("what if Backblaze is down on the day Postgres dies"). rclone already handles multiple backends; the work is the env shape (`B2_*` vs `R2_*` vs generic `DEST_N_*`?) and idempotent partial-failure behavior.

### v0.5.0 — file integrity verification
Periodic spot-check that uploaded `.age` files in B2 still exist and decrypt cleanly with a public key check (without needing the secret key). Catches silent B2 corruption / accidental deletion / lifecycle rule misfires.

## Deferred / under consideration

### Cross-app status board (status JSON in B2)
**Original idea:** the runner writes `_status/<app>-<env>.json` to B2 after each run with `{last_success, last_failure, size_bytes, duration, runner_version}`. A tiny static HTML page reads those JSONs and renders a board across all adopting apps.

**Why deferred:** Healthchecks.io's dashboard already covers "is everything green across all my apps" for free. The status JSON would add per-run sizes and durations, which are nice-to-have but not load-bearing. Revisit if you find yourself wanting to answer "is backup file size trending up unexpectedly?" without logging into B2.

If/when picked up: probably an opt-in `STATUS_JSON_URL` (or `STATUS_JSON_PREFIX`) env var so it stays fully optional.

### Self-hosted ping endpoint instead of hosted Healthchecks.io
**The idea:** `HEALTHCHECK_URL` is just a URL, so it already works against a
self-hosted dead-man's switch today — an Uptime Kuma push monitor, a Gatus
endpoint, a self-hosted Healthchecks instance. No SafeKeep change needed. The
question is whether the VPS apps *should* point there.

**Why not yet (2026-08-19):** the alert path should not share a failure domain
with anything it watches, and it should not depend on infrastructure that can
be down for unrelated reasons. Homelab down means silent VPS backups with no
signal — the exact failure this layer exists to catch. It would also put
production alerting on the tailnet, adding a dependency between two systems
that are currently independent.

**Worth re-asking when:** the homelab monitoring stack has its own external
watchdog (something outside the house confirming Kuma itself is alive), at
which point self-hosting stops being a single point of silence. Also worth
re-asking if the hosted free tier ever stops fitting — 3 apps × 1 production
check each is nowhere near it today.

### Sentry breadcrumb on failure
Was in the original v0.1.1 plan. Dropped because it duplicates Layer 1 (SMTP), couples to Sentry config, and Sentry's "cron monitor" feature solves a different problem. Adopters who want it can wire `curl` to Sentry's webhook themselves via a custom `ALERT_WEBHOOK_URL` (which doesn't exist yet — would be its own small feature).

### Alert debouncing
If credentials break and the loop fails 24 times in 24h, today you get 24 emails. Options:
- Add `ALERT_DEBOUNCE_HOURS` env var
- Track last alert time in `/state/last-alert.txt`, suppress repeats within window

Defer until someone actually hits this. Most adopters won't.

### Weekly success digest email
"Heartbeat" email summarizing the week's backups even when nothing failed. Healthchecks.io kind of does this if you check the dashboard; an email push is a different UX. Defer.

### `/start` ping for HC.io duration tracking
Healthchecks.io supports `<url>/start` then `<url>` to measure backup duration. Nice to have for trend analysis. Defer.

### Move to a generic SQL dump abstraction
Currently Postgres-only. MySQL/MariaDB would need a different `dump` step. Probably not worth it until an actual user appears who needs it — keeps the surface tight.

## Open questions worth re-asking

These don't have answers yet; the answer depends on real-world data we don't have:

1. **Single bucket vs per-app bucket.** Default is single bucket. At many adopters, is per-app isolation worth the extra B2 keys to manage? Probably no, but worth re-asking annually.
2. **Bucket lifecycle rule.** Today: `REMOTE_RETENTION_DAYS=30` in the runner does the pruning. If the runner ever stops cleanly without erroring, files accumulate. A B2 "keep last 60 days" lifecycle rule is a free safety net. Defer until 30+ days of clean operation.
3. **Should there be a `:latest` tag on GHCR?** Currently no — adopters pin to `vX.Y.Z`. `:latest` would let auto-update tools like Watchtower track new versions, at the cost of accidental breakage on bad releases. Keep pinned for now.
4. **Restore-validation hosting (when v0.2.0 ships).** Same VPS (resource-constrained), GitHub Actions runner (slow Postgres bootstrap on every dump), dedicated tiny Hetzner box ($5/mo). Likely the third.
