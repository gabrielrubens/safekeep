# SafeKeep

Off-site, encrypted Postgres backups in a single container. Drop it next to your database as a Kamal accessory, set a handful of env vars, and your data is dumped, encrypted client-side with [age](https://age-encryption.org), and uploaded to Backblaze B2 on a schedule. One image works for any app, framework, or language.

**Image:** `ghcr.io/gabrielrubens/safekeep:v0.1.1` (public on GHCR)
**Status:** v0.1.0 in production at Pensio since 2026-04-26. v0.1.1 is the first release under the standalone repo and adds opt-in alerting (SMTP + Healthchecks.io).

## Why SafeKeep

- **Survives host renames and host moves.** No host-side cron, no scripts under `/opt/<app>/`. The accessory inherits Kamal's logging, restart policy, and lifecycle. Same model as the `postgres` accessory.
- **Encrypted client-side.** Only the public `age` recipient lives in the container. The secret key never goes near the VPS — a B2 credential leak never exposes plaintext.
- **One image, many apps.** Each adopting app injects its own `PG_HOST`, `BACKUP_PREFIX`, and secrets. Cuts maintenance to one source tree.
- **Self-restorable.** A single `kamal accessory exec` rebuilds the database from the latest dump, local or remote.
- **Opt-in alerting.** SMTP email on failure, Healthchecks.io ping on success. Both gated on env vars — set what you want, leave the rest blank.

## Architecture

```
┌──────────────────────┐
│  Postgres accessory  │   e.g. pensio-postgres
└──────┬───────────────┘
       │ pg_dump (internal Docker DNS)
       ▼
┌──────────────────────────────────────────┐
│  SafeKeep accessory                      │
│  same VPS, same Docker network           │
│                                          │
│  loop:                                   │
│    1. pg_dump | gzip → /state/dumps/     │
│    2. age -r <pubkey> → .sql.gz.age      │
│    3. rclone copy → b2:<bucket>/<prefix> │
│    4. prune local + remote (retention)   │
│    5. write /state/last-success.txt      │
│    6. (v0.1.1) email or HC.io ping       │
│    7. sleep BACKUP_INTERVAL              │
└──────────────────────────────────────────┘
                │
                ▼
        ┌────────────────────┐
        │  Backblaze B2      │
        │  Object Lock + SSE │
        └────────────────────┘
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design rationale and decision record.

## Deploy as a Kamal accessory

```yaml
# config/deploy.{production,staging}.yml
accessories:
  backup:
    image: ghcr.io/gabrielrubens/safekeep:v0.1.1
    host: <your-vps-ip>
    cmd: /usr/local/bin/entrypoint.sh loop
    env:
      clear:
        BACKUP_INTERVAL: 86400              # daily; use 21600 for 6-hourly
        INITIAL_DELAY: 60
        PG_HOST: myapp-postgres
        PG_USER: myapp
        PG_DB: myapp
        BACKUP_PREFIX: myapp-prod           # B2 path prefix + filename prefix
        LOCAL_RETENTION_DAYS: 7
        REMOTE_RETENTION_DAYS: 30
        B2_BUCKET: my-backups
        AGE_RECIPIENT: age1abc...           # public key — not secret, fine in env.clear
      secret:
        - PG_PASSWORD:POSTGRES_PASSWORD     # alias the existing accessory secret
        - B2_KEY_ID
        - B2_APP_KEY
    directories:
      - data:/state                          # local dumps survive container restarts
```

Then:

```bash
kamal accessory boot backup -d production
kamal accessory boot backup -d staging
kamal accessory logs backup -d production -f
```

## Operational commands

```bash
# Tail the loop
kamal accessory logs backup -d production -f

# Force a backup now (one-off, exits after running)
kamal accessory exec backup --reuse "/usr/local/bin/entrypoint.sh once" -d production

# Restore latest local dump (DESTRUCTIVE — drops existing schema first)
kamal accessory exec backup --reuse "/usr/local/bin/restore.sh latest" -d production

# Restore from B2 (requires age secret key copied into the container)
docker cp ~/.config/safekeep/master.key <accessory-container>:/tmp/age.key
kamal accessory exec backup --reuse \
  "/usr/local/bin/restore.sh latest --remote --age-key /tmp/age.key" -d production

# Decrypt a downloaded .age file locally
age -d -i ~/.config/safekeep/master.key -o restored.sql.gz myapp-prod-...sql.gz.age
```

## Env vars

### Required

| Var | Purpose |
|---|---|
| `PG_HOST` | Postgres hostname (Kamal accessory name) |
| `PG_USER` | Postgres user |
| `PG_DB` | Postgres database |
| `PG_PASSWORD` | Postgres password |
| `B2_BUCKET` | Backblaze B2 bucket name |
| `B2_KEY_ID` | Backblaze Application Key ID |
| `B2_APP_KEY` | Backblaze Application Key |

### Optional — backup loop

| Var | Default | Purpose |
|---|---|---|
| `PG_PORT` | `5432` | |
| `BACKUP_PREFIX` | `$PG_DB` | B2 path prefix and dump filename prefix |
| `BACKUP_INTERVAL` | `86400` | Loop interval in seconds (daily) |
| `INITIAL_DELAY` | `60` | Wait before first run, prevents thrash on restart loops |
| `LOCAL_RETENTION_DAYS` | `7` | Local dumps older than this are deleted |
| `REMOTE_RETENTION_DAYS` | `30` | Remote dumps older than this are deleted |
| `AGE_RECIPIENT` | empty | age public key. **Strongly recommended.** If unset, dumps upload as plaintext. |

### Optional — alerting (v0.1.1+)

Set these to enable each layer. Anything left unset is silently skipped.

| Var | Layer | Purpose |
|---|---|---|
| `SMTP_HOST` | SMTP email on failure | Hostname (e.g. `smtp-relay.brevo.com`) |
| `SMTP_PORT` | " | Default `587` |
| `SMTP_USER` | " | SMTP username |
| `SMTP_PASSWORD` | " | SMTP password |
| `SMTP_FROM` | " | From address |
| `ALERT_RECIPIENTS` | " | Comma-separated To addresses |
| `APP_NAME` | " | Used in subject line; defaults to first segment of `BACKUP_PREFIX` |
| `HEALTHCHECK_URL` | Healthchecks.io ping on success | Full ping URL from healthchecks.io |

## Generating an age keypair (one-time)

```bash
mkdir -p ~/.config/safekeep
age-keygen -o ~/.config/safekeep/master.key
chmod 600 ~/.config/safekeep/master.key
```

- **Public key** (the `# public key:` line, starts `age1...`) → set as `AGE_RECIPIENT` in `env.clear`. Safe to commit-adjacent, can only encrypt.
- **Secret key** (the `AGE-SECRET-KEY-...` line) → 1Password (or your password manager) + the local file. **Never** put this on the VPS, never in env vars. Without it, no backup can be decrypted — including by you.

One keypair across all your apps is fine. One bucket across all your apps is fine. Use per-app `BACKUP_PREFIX` to keep B2 paths tidy.

## Backblaze B2 setup (one-time)

1. **Bucket** — Private, Object Lock = Compliance, SSE-B2 encryption (free, AES-256).
2. **Application Key** scoped to that bucket with `listFiles`, `readFiles`, `writeFiles`, `deleteFiles` capabilities. B2 displays the App Key **once** — copy it immediately.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full rationale on these choices.

## Build & push

```bash
docker build --platform linux/amd64 -t ghcr.io/gabrielrubens/safekeep:vX.Y.Z .
docker push ghcr.io/gabrielrubens/safekeep:vX.Y.Z
```

Or push a `vX.Y.Z` git tag and the GitHub Actions workflow at [.github/workflows/release.yml](.github/workflows/release.yml) will build and push for you.

## Roadmap

See [ROADMAP.md](ROADMAP.md). Highlights: pre-upload restore validation, file backups (`/app/media`), multi-destination upload (B2 + R2), cross-app status board.

## License

MIT — see [LICENSE](LICENSE).
