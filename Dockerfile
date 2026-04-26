# =============================================================================
# SafeKeep — generic Postgres backup container
# =============================================================================
# Schedules pg_dump → age encryption → B2 upload, on a configurable interval.
# Designed to be deployed as a Kamal accessory alongside an app's primary
# Postgres accessory. Framework-agnostic: same image works for any app.
#
# Why FROM postgres:18-alpine: pg_dump version must match (or exceed) the
# server. Bump the base tag in lockstep with your Postgres major version.
# =============================================================================
FROM postgres:18-alpine

LABEL org.opencontainers.image.source="https://github.com/gabrielrubens/safekeep"
LABEL org.opencontainers.image.description="SafeKeep — Postgres → age → B2 backup runner. Run as a Kamal accessory."
LABEL org.opencontainers.image.licenses="MIT"

USER root

# Runtime tools:
#   rclone     — uploads to B2 (and any other rclone backend later)
#   age        — modern client-side encryption (https://age-encryption.org)
#   bash       — entrypoint scripts
#   findutils  — needed for `find -mtime` retention
#   tzdata     — for human-readable UTC timestamps
RUN apk add --no-cache \
        rclone \
        age \
        bash \
        coreutils \
        gzip \
        findutils \
        tzdata \
        ca-certificates \
    && update-ca-certificates

WORKDIR /usr/local/bin

COPY entrypoint.sh backup.sh backup-loop.sh restore.sh ./
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/backup.sh \
             /usr/local/bin/backup-loop.sh \
             /usr/local/bin/restore.sh

# /state holds local dumps. Mount via Kamal `directories: data:/state`.
VOLUME ["/state"]

# Default: run the loop. Override CMD for one-off runs:
#   docker run … entrypoint.sh once
#   docker run … entrypoint.sh restore latest
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["loop"]
