# SafeKeep

## About
SafeKeep is a single-container Postgres backup runner: `pg_dump` → age encryption → Backblaze B2 upload, on a schedule. Deployed as a Kamal accessory by adopting apps. Framework-agnostic — same image works for any app.

This project is intentionally **small and slow-moving**. The whole codebase is ~5 bash scripts + a Dockerfile. Resist scope creep.

## Project layout
```
safekeep/
├── README.md             # Product-facing — what it is, how to deploy, env vars table
├── ARCHITECTURE.md       # Decision record + the monitoring layers
├── ROADMAP.md            # Shipped / In progress / Planned / Deferred
├── CLAUDE.md             # This file
├── LICENSE               # MIT
├── Dockerfile            # FROM postgres:N-alpine + apk add for runtime tools
├── entrypoint.sh         # Dispatcher: loop | once | restore | shell
├── backup-loop.sh        # Long-running scheduler (sleep + call backup.sh)
├── backup.sh             # One-shot: pg_dump → encrypt → upload → prune → mark
├── restore.sh            # One-shot: fetch → decrypt → psql
└── .github/
    └── workflows/
        └── release.yml   # Tag-triggered multi-arch image build to GHCR
```

That's the whole repo. Don't add directories without a clear reason.

## Stack (non-negotiable)
- **Base image:** `postgres:N-alpine` — `pg_dump` major version must match the server we back up
- **Encryption:** [age](https://age-encryption.org) — modern, single binary, single recipient string, no keyring
- **Upload:** [rclone](https://rclone.org) — handles B2 today, opens the door to R2/S3/etc. later
- **Scripting:** bash + `set -euo pipefail`. No Python, no Go, no other languages
- **CI:** one GHA workflow at `.github/workflows/release.yml`. Don't add more
- **Tests:** no test framework. Smoke-test manually before tagging (see "Pre-release checklist")

## Versioning & releases
SemVer (`vX.Y.Z`):

| Bump | When |
|---|---|
| **PATCH** (v0.1.X) | Bug fix, doc-only change, internal refactor — no env var changes, no behavior change for adopters |
| **MINOR** (v0.X.0) | New feature, new optional env var, new alerting layer — must stay backward-compatible with existing adopters' env contracts |
| **MAJOR** (vX.0.0) | Breaking change to env vars, removed feature, base image major bump that requires adopter action — coordinate with Pensio + any other adopters first |

**Release flow:**
1. Make changes on `main` (this is a small repo, no branch dance needed)
2. Run the pre-release checklist below
3. Update `ROADMAP.md` — move shipped item from "In progress" / "Planned" to "Shipped" with date
4. Update `README.md` env vars table if anything changed
5. Commit any doc updates
6. `git tag vX.Y.Z` then `git push --tags`
7. GHA builds and pushes `ghcr.io/gabrielrubens/safekeep:vX.Y.Z` (multi-arch: amd64 + arm64)
8. Verify image landed: `docker pull ghcr.io/gabrielrubens/safekeep:vX.Y.Z`
9. Create a GitHub release with notes — pull from the relevant ROADMAP section

**No `:latest` tag.** Adopters pin to `vX.Y.Z` so a bad release can't break them on `kamal accessory reboot`.

## Pre-release checklist
Before tagging, manually:

```bash
# Syntax check every shell script
bash -n entrypoint.sh backup.sh backup-loop.sh restore.sh

# If shellcheck is installed (recommended)
shellcheck entrypoint.sh backup.sh backup-loop.sh restore.sh

# Verify the image builds (catches Dockerfile typos, missing apk packages)
docker build --platform linux/amd64 -t safekeep:test .
```

For changes that touch the backup loop, encryption, or upload paths — also run an end-to-end smoke test against a throwaway Postgres + B2 bucket. The full process is in `ARCHITECTURE.md` under "Testing locally" (add that section if you ever need it).

## Commit format
- `feat: <description>` — new behavior visible to adopters
- `fix: <description>` — bug fix
- `docs: <description>` — README / ARCHITECTURE / ROADMAP / CLAUDE only
- `chore: <description>` — internal cleanup, dependency bumps
- `vX.Y.Z: <short description>` — the release commit (if you need a dedicated one; usually a tag on the latest feat/fix commit is enough)

**Never use `Co-Authored-By:` or other agent-attribution trailers.** Plain commit messages.

## When to update what
- **README.md** — any change to env vars, deploy recipe, ops commands. The README is the contract with adopters
- **ARCHITECTURE.md** — design tradeoff revisited, new monitoring layer, change to "what's intentionally NOT in SafeKeep"
- **ROADMAP.md** — feature shipped (move to Shipped with date), new idea (add to Deferred with rationale), planned item picked up (move to In progress)
- **Dockerfile labels** — base image bump, license change

## Pushing
Push freely to `main`. The image only publishes on a `vX.Y.Z` tag, so a doc-only commit or work-in-progress doesn't affect any adopter. Adopters pin and only pick up changes when they bump.

For releases: tag → push tag → GHA does the rest.

## Adopters
Pensio is the reference adopter today. Their wiring lives in:
- `~/dev/pensio/config/deploy.yml` (shared accessory block)
- `~/dev/pensio/config/deploy.{staging,production}.yml` (per-env overrides)
- `~/dev/pensio/docs/admin/backup-system.md` (Pensio-side wiring + restore runbook)

The Blueprint adoption recipe lives at `~/dev/blueprint/04-deploy/backups.md` — keep that doc in sync with the README's "Deploy as a Kamal accessory" section when env vars change.

## Rules for LLMs
- **Stay small.** Resist adding test frameworks, alternative languages, monitoring integrations, web UIs, or anything that grows the surface
- **Bash + Dockerfile only.** No Python helpers, no Go rewrites
- **Backward-compatible env contract within a MAJOR.** Renaming `BACKUP_PREFIX` is a breaking change — every adopter's B2 paths derive from it. Adding a new optional env var is fine
- **The age secret key MUST NEVER appear in the container, in env vars, in any source file, or in CI.** Only the public `AGE_RECIPIENT` ever lives near the runner
- **No `:latest` tag** without an explicit decision. Adopters pin
- **Helper failures must not propagate.** Email/webhook/healthcheck failures inside `backup.sh` log a warning and continue — the backup itself is the priority
- **Document new env vars in the README env table on the same commit they're introduced**
- **Verify Pensio's wiring still works** (read `~/dev/pensio/config/deploy.yml` and the staging/production overrides) before any change that touches env-var names or the entrypoint contract
