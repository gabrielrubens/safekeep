#!/bin/bash
# =============================================================================
# Single-shot Postgres backup → age encryption → B2 upload
# =============================================================================
# Called by backup-loop.sh on a schedule, or directly via `entrypoint.sh once`.
#
# Required env:
#   PG_HOST, PG_USER, PG_DB, PG_PASSWORD
#   B2_BUCKET, B2_KEY_ID, B2_APP_KEY
#
# Optional env:
#   PG_PORT                 (default 5432)
#   BACKUP_PREFIX           (default: $PG_DB; used as B2 path prefix + filename prefix)
#   AGE_RECIPIENT           (age public key; if unset, NO ENCRYPTION — not recommended)
#   LOCAL_RETENTION_DAYS    (default 7)
#   REMOTE_RETENTION_DAYS   (default 30)
#
# Files:
#   /state/dumps/<prefix>-<utc-timestamp>.sql.gz       (local, plaintext)
#   b2:<bucket>/<prefix>/<prefix>-<utc-timestamp>.sql.gz.age  (remote, encrypted)
#   /state/last-success.txt                             (UTC of last OK run)
# =============================================================================
set -euo pipefail

: "${PG_HOST:?PG_HOST required (e.g. pensio-postgres)}"
: "${PG_USER:?PG_USER required}"
: "${PG_DB:?PG_DB required}"
: "${PG_PASSWORD:?PG_PASSWORD required}"
: "${B2_BUCKET:?B2_BUCKET required}"
: "${B2_KEY_ID:?B2_KEY_ID required}"
: "${B2_APP_KEY:?B2_APP_KEY required}"

PG_PORT="${PG_PORT:-5432}"
BACKUP_PREFIX="${BACKUP_PREFIX:-$PG_DB}"
LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-7}"
REMOTE_RETENTION_DAYS="${REMOTE_RETENTION_DAYS:-30}"
AGE_RECIPIENT="${AGE_RECIPIENT:-}"

LOCAL_DIR=/state/dumps
mkdir -p "$LOCAL_DIR"

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
DUMP_FILE="$LOCAL_DIR/${BACKUP_PREFIX}-${TIMESTAMP}.sql.gz"
ENCRYPTED_FILE=""

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [backup] $*"; }

log "Dumping ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB} → ${DUMP_FILE}"
PGPASSWORD="$PG_PASSWORD" pg_dump \
    -h "$PG_HOST" \
    -p "$PG_PORT" \
    -U "$PG_USER" \
    -d "$PG_DB" \
    --clean --if-exists --no-owner --no-privileges \
    | gzip > "$DUMP_FILE"

DUMP_SIZE=$(stat -c%s "$DUMP_FILE")
log "Dumped ${DUMP_SIZE} bytes"

# Sanity check: refuse to upload obviously-broken (tiny) dumps
if [ "$DUMP_SIZE" -lt 1024 ]; then
    log "ERROR: dump file < 1KB, refusing to upload"
    exit 1
fi

# Encrypt for upload (keep local plain for easy `zcat` inspection)
UPLOAD_FILE="$DUMP_FILE"
if [ -n "$AGE_RECIPIENT" ]; then
    ENCRYPTED_FILE="${DUMP_FILE}.age"
    age -r "$AGE_RECIPIENT" -o "$ENCRYPTED_FILE" "$DUMP_FILE"
    UPLOAD_FILE="$ENCRYPTED_FILE"
    log "Encrypted with age → $(stat -c%s "$ENCRYPTED_FILE") bytes"
else
    log "WARN: AGE_RECIPIENT not set, uploading plaintext"
fi

# Configure rclone for B2 (per-run; idempotent; no persistent state)
mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf <<EOF
[b2]
type = b2
account = ${B2_KEY_ID}
key = ${B2_APP_KEY}
hard_delete = false
EOF

B2_DEST="b2:${B2_BUCKET}/${BACKUP_PREFIX}/"
log "Uploading to ${B2_DEST}$(basename "$UPLOAD_FILE")"
rclone copy "$UPLOAD_FILE" "$B2_DEST" --quiet

# Drop the encrypted artifact locally; the plain dump stays for inspection
if [ -n "$ENCRYPTED_FILE" ]; then
    rm -f "$ENCRYPTED_FILE"
fi

# Local retention
log "Pruning local dumps older than ${LOCAL_RETENTION_DAYS} days"
find "$LOCAL_DIR" -name "${BACKUP_PREFIX}-*.sql.gz" -mtime +"${LOCAL_RETENTION_DAYS}" -delete

# Remote retention
log "Pruning remote dumps older than ${REMOTE_RETENTION_DAYS} days"
rclone delete --min-age "${REMOTE_RETENTION_DAYS}d" "$B2_DEST" --quiet \
    || log "WARN: remote prune had errors (non-fatal)"

# Mark success — useful for external monitoring (e.g. Sentry cron monitor or
# a separate watchdog: alert if /state/last-success.txt is older than 25 hours)
date -u +%Y-%m-%dT%H:%M:%SZ > /state/last-success.txt

log "OK: ${BACKUP_PREFIX} ${TIMESTAMP}"
