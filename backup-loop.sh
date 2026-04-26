#!/bin/bash
# =============================================================================
# Long-running scheduler that calls backup.sh every BACKUP_INTERVAL seconds
# =============================================================================
# Default loop is the Kamal accessory's CMD. Failures don't kill the loop —
# we log and retry next interval, so a transient B2 outage doesn't take the
# whole accessory down.
#
# Env:
#   BACKUP_INTERVAL    seconds between runs (default 86400 = daily; 21600 = 6h)
#   INITIAL_DELAY      seconds to wait before first run (default 60)
#                      → avoids piling up runs on container restart loops
# =============================================================================
set -euo pipefail

BACKUP_INTERVAL="${BACKUP_INTERVAL:-86400}"
INITIAL_DELAY="${INITIAL_DELAY:-60}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [loop] $*"; }

log "Starting backup loop, interval=${BACKUP_INTERVAL}s, initial_delay=${INITIAL_DELAY}s"
sleep "$INITIAL_DELAY"

while true; do
    log "Triggering backup"
    if /usr/local/bin/backup.sh; then
        log "Backup OK, sleeping ${BACKUP_INTERVAL}s"
    else
        rc=$?
        log "ERROR: backup exited with $rc; sleeping ${BACKUP_INTERVAL}s before retry"
    fi
    sleep "$BACKUP_INTERVAL"
done
