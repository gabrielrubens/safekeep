#!/bin/bash
# =============================================================================
# Restore a Postgres dump (local or remote) into the configured DB
# =============================================================================
# Usage (inside the running backup container, via Kamal):
#   kamal accessory exec backup --reuse "/usr/local/bin/restore.sh latest"
#   kamal accessory exec backup --reuse "/usr/local/bin/restore.sh 20260426T030000Z"
#
# Remote restore (from B2):
#   kamal accessory exec backup --reuse "/usr/local/bin/restore.sh latest --remote --age-key /run/secrets/age.key"
#
# To pass the age secret key in for decryption, mount it via Kamal secrets
# or `docker cp` into the container, then point --age-key at the path.
#
# WARNING: --clean in the dump means existing schema is dropped before
# restore. Run with care and consider taking a fresh dump first.
# =============================================================================
set -euo pipefail

: "${PG_HOST:?required}"
: "${PG_USER:?required}"
: "${PG_DB:?required}"
: "${PG_PASSWORD:?required}"

PG_PORT="${PG_PORT:-5432}"
BACKUP_PREFIX="${BACKUP_PREFIX:-$PG_DB}"
LOCAL_DIR=/state/dumps

target="${1:-}"
mode="local"
age_key=""

if [ -z "$target" ]; then
    cat <<USAGE >&2
Usage: restore.sh <timestamp|latest> [--remote [--age-key <path>]]

  timestamp   UTC timestamp (e.g. 20260426T030000Z)
  latest      newest dump from the source

  --remote          fetch from B2 instead of /state/dumps
  --age-key PATH    age secret key to decrypt remote .age dump
USAGE
    exit 2
fi

# Parse remaining flags
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --remote)   mode="remote"; shift ;;
        --age-key)  age_key="$2"; shift 2 ;;
        *)          echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [restore] $*"; }

DUMP_FILE=""
TMP_FILES=()

cleanup() {
    for f in "${TMP_FILES[@]:-}"; do
        [ -n "$f" ] && rm -f "$f"
    done
}
trap cleanup EXIT

if [ "$mode" = "remote" ]; then
    : "${B2_BUCKET:?required for --remote}"
    : "${B2_KEY_ID:?required for --remote}"
    : "${B2_APP_KEY:?required for --remote}"

    mkdir -p /root/.config/rclone
    cat > /root/.config/rclone/rclone.conf <<EOF
[b2]
type = b2
account = ${B2_KEY_ID}
key = ${B2_APP_KEY}
EOF

    B2_DIR="b2:${B2_BUCKET}/${BACKUP_PREFIX}"

    if [ "$target" = "latest" ]; then
        match=$(rclone lsf "$B2_DIR/" --include "${BACKUP_PREFIX}-*.sql.gz*" 2>/dev/null | sort -r | head -1 || true)
    else
        match=$(rclone lsf "$B2_DIR/" --include "${BACKUP_PREFIX}-${target}.sql.gz*" 2>/dev/null | head -1 || true)
    fi

    if [ -z "$match" ]; then
        log "ERROR: no remote dump found at $B2_DIR/ for target=$target"
        exit 1
    fi

    log "Downloading $B2_DIR/$match"
    rclone copy "$B2_DIR/$match" /tmp/ --quiet
    DUMP_FILE="/tmp/$match"
    TMP_FILES+=("$DUMP_FILE")

    if [[ "$DUMP_FILE" == *.age ]]; then
        if [ -z "$age_key" ] || [ ! -f "$age_key" ]; then
            log "ERROR: encrypted dump but --age-key not provided or unreadable"
            exit 1
        fi
        decrypted="${DUMP_FILE%.age}"
        age -d -i "$age_key" -o "$decrypted" "$DUMP_FILE"
        TMP_FILES+=("$decrypted")
        DUMP_FILE="$decrypted"
        log "Decrypted to $DUMP_FILE"
    fi
else
    if [ "$target" = "latest" ]; then
        DUMP_FILE=$(ls -1t "$LOCAL_DIR"/"${BACKUP_PREFIX}"-*.sql.gz 2>/dev/null | head -1 || true)
    else
        DUMP_FILE="$LOCAL_DIR/${BACKUP_PREFIX}-${target}.sql.gz"
    fi
fi

if [ -z "$DUMP_FILE" ] || [ ! -f "$DUMP_FILE" ]; then
    log "ERROR: dump file not found: ${DUMP_FILE:-<empty>}"
    exit 1
fi

log "Restoring from $DUMP_FILE → ${PG_USER}@${PG_HOST}:${PG_PORT}/${PG_DB}"
log "WARNING: --clean DROPs existing schema. Pausing 5s for Ctrl-C..."
sleep 5

zcat "$DUMP_FILE" | PGPASSWORD="$PG_PASSWORD" psql \
    -h "$PG_HOST" \
    -p "$PG_PORT" \
    -U "$PG_USER" \
    -d "$PG_DB" \
    --quiet

log "OK: restore complete"
