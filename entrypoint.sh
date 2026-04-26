#!/bin/bash
# Top-level entrypoint dispatcher. Selected by docker `CMD`.
set -euo pipefail

cmd="${1:-loop}"

case "$cmd" in
    loop)
        # Long-running scheduled backup loop. Default for the Kamal accessory.
        exec /usr/local/bin/backup-loop.sh
        ;;
    once)
        # Run a single backup and exit. Useful for ad-hoc invocations:
        #   kamal accessory exec backup --reuse "/usr/local/bin/entrypoint.sh once"
        exec /usr/local/bin/backup.sh
        ;;
    restore)
        shift
        exec /usr/local/bin/restore.sh "$@"
        ;;
    shell|sh|bash)
        exec /bin/bash
        ;;
    *)
        echo "Usage: $(basename "$0") {loop|once|restore <args>|shell}" >&2
        exit 2
        ;;
esac
