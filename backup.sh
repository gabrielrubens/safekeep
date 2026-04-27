#!/bin/bash
# =============================================================================
# Single-shot Postgres backup → age encryption → B2 upload + opt-in alerting
# =============================================================================
# Called by backup-loop.sh on a schedule, or directly via `entrypoint.sh once`.
#
# Required env:
#   PG_HOST, PG_USER, PG_DB, PG_PASSWORD
#   B2_BUCKET, B2_KEY_ID, B2_APP_KEY
#
# Optional env (backup loop):
#   PG_PORT                 (default 5432)
#   BACKUP_PREFIX           (default: $PG_DB; used as B2 path prefix + filename prefix)
#   AGE_RECIPIENT           (age public key; if unset, NO ENCRYPTION — not recommended)
#   LOCAL_RETENTION_DAYS    (default 7)
#   REMOTE_RETENTION_DAYS   (default 30)
#   BACKUP_INTERVAL         (default 86400; included in failure email body)
#
# Optional env (alerting — gated on SMTP_HOST / HEALTHCHECK_URL presence):
#   SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD, SMTP_FROM, ALERT_RECIPIENTS
#                           Failure email via msmtp. Recipients are comma-separated.
#   HEALTHCHECK_URL         Pinged on every successful run (Healthchecks.io et al.)
#   APP_NAME                Used in failure-email subject; defaults to first segment of BACKUP_PREFIX
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
BACKUP_INTERVAL="${BACKUP_INTERVAL:-86400}"

# Optional alerting (all gated on env presence; helpers exit early if unset)
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_FROM="${SMTP_FROM:-}"
ALERT_RECIPIENTS="${ALERT_RECIPIENTS:-}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
APP_NAME="${APP_NAME:-${BACKUP_PREFIX%%-*}}"

LOCAL_DIR=/state/dumps
mkdir -p "$LOCAL_DIR"

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
DUMP_FILE="$LOCAL_DIR/${BACKUP_PREFIX}-${TIMESTAMP}.sql.gz"
ENCRYPTED_FILE=""

# Per-step stderr capture so failure emails can include diagnostic context
DUMP_ERR=$(mktemp)
ENCRYPT_ERR=$(mktemp)
UPLOAD_ERR=$(mktemp)

# Tracked by the EXIT trap to know which step (if any) was running when we died
FAILED_STEP=""
FAILED_LOG=""

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [backup] $*"; }

# ---------------------------------------------------------------------------
# Alerting helpers — all gated on env presence; failures MUST NOT propagate
# (the backup itself is the priority, alerting is best-effort)
# ---------------------------------------------------------------------------

notify_email() {
    [ -z "$SMTP_HOST" ] && return 0
    [ -z "$ALERT_RECIPIENTS" ] && return 0
    if [ -z "$SMTP_FROM" ]; then
        log "WARN: SMTP_FROM unset, skipping failure email"
        return 0
    fi

    local failed_step="$1"
    local err_log="$2"
    local subject="[${APP_NAME}] Backup FAILED — ${BACKUP_PREFIX}"
    local now rfc_date
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    rfc_date=$(date -u +'%a, %d %b %Y %H:%M:%S +0000')

    local msmtprc
    msmtprc=$(mktemp)
    chmod 600 "$msmtprc"
    cat > "$msmtprc" <<MSMTPCFG
defaults
auth on
tls on
tls_starttls on

account default
host ${SMTP_HOST}
port ${SMTP_PORT}
from ${SMTP_FROM}
user ${SMTP_USER}
password ${SMTP_PASSWORD}
MSMTPCFG

    {
        echo "From: ${SMTP_FROM}"
        echo "To: ${ALERT_RECIPIENTS}"
        echo "Subject: ${subject}"
        echo "Date: ${rfc_date}"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo ""
        echo "Backup failed for ${BACKUP_PREFIX} at ${now}."
        echo ""
        echo "Failed step:     ${failed_step}"
        echo "Database:        ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB}"
        echo "Hostname:        $(hostname)"
        echo "Loop will retry: in ${BACKUP_INTERVAL} seconds"
        echo ""
        echo "--- Error output (last 20 lines) ---"
        tail -20 "${err_log}" 2>/dev/null || echo "(no error output captured)"
    } | msmtp -C "$msmtprc" -t 2>&1 \
        || log "WARN: msmtp failed to send alert (continuing)"

    rm -f "$msmtprc"
    log "Failure alert sent to: ${ALERT_RECIPIENTS}"
}

ping_healthcheck() {
    [ -z "$HEALTHCHECK_URL" ] && return 0
    if curl --max-time 5 -fsS "$HEALTHCHECK_URL" >/dev/null 2>&1; then
        log "Healthcheck pinged: ${HEALTHCHECK_URL}"
    else
        log "WARN: healthcheck ping failed (continuing)"
    fi
}

# Final cleanup + alerting on exit (success or failure)
on_exit() {
    local exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        ping_healthcheck
    elif [ -n "$FAILED_STEP" ]; then
        log "ERROR: backup failed at step '${FAILED_STEP}' (exit ${exit_code})"
        notify_email "$FAILED_STEP" "$FAILED_LOG"
    fi
    rm -f "$DUMP_ERR" "$ENCRYPT_ERR" "$UPLOAD_ERR"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Main backup flow
# ---------------------------------------------------------------------------

log "Dumping ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB} → ${DUMP_FILE}"
FAILED_STEP="pg_dump"
FAILED_LOG="$DUMP_ERR"
PGPASSWORD="$PG_PASSWORD" pg_dump \
    -h "$PG_HOST" \
    -p "$PG_PORT" \
    -U "$PG_USER" \
    -d "$PG_DB" \
    --clean --if-exists --no-owner --no-privileges \
    2>"$DUMP_ERR" \
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
    FAILED_STEP="age encrypt"
    FAILED_LOG="$ENCRYPT_ERR"
    age -r "$AGE_RECIPIENT" -o "$ENCRYPTED_FILE" "$DUMP_FILE" 2>"$ENCRYPT_ERR"
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
FAILED_STEP="rclone upload"
FAILED_LOG="$UPLOAD_ERR"
rclone copy "$UPLOAD_FILE" "$B2_DEST" --quiet 2>"$UPLOAD_ERR"

# Drop the encrypted artifact locally; the plain dump stays for inspection
if [ -n "$ENCRYPTED_FILE" ]; then
    rm -f "$ENCRYPTED_FILE"
fi

# Post-upload housekeeping (warnings only — we already have the upload)
log "Pruning local dumps older than ${LOCAL_RETENTION_DAYS} days"
find "$LOCAL_DIR" -name "${BACKUP_PREFIX}-*.sql.gz" -mtime +"${LOCAL_RETENTION_DAYS}" -delete

log "Pruning remote dumps older than ${REMOTE_RETENTION_DAYS} days"
rclone delete --min-age "${REMOTE_RETENTION_DAYS}d" "$B2_DEST" --quiet \
    || log "WARN: remote prune had errors (non-fatal)"

# Mark success — clears FAILED_STEP so the on_exit trap takes the success path
FAILED_STEP=""
date -u +%Y-%m-%dT%H:%M:%SZ > /state/last-success.txt

log "OK: ${BACKUP_PREFIX} ${TIMESTAMP}"
