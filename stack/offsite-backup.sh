#!/usr/bin/env bash
# Offsite backup of the serving primary to an S3-compatible bucket (Cloudflare R2)
# with restic: encrypted, deduplicated, with retention.
#
# Runs from vps-git-offsite-backup.timer on both nodes, but only the node that
# is actually serving does anything: ROLE=primary and Forgejo running (so a
# standby or a fenced node exits quietly). Snapshots use a fixed --host, so
# backups from either node form one history after a failover.
#
#   pg_dump -Fc + forgejo_data volume -> restic backup
#   restic forget --keep-daily 30 --keep-monthly 12 --prune
#   Sundays: restic check --read-data-subset 5%
#
# Secrets live outside the repo, created by hand:
#   /etc/vps-git-backup/r2.env           RESTIC_REPOSITORY, AWS_* (see r2.env.example)
#   /etc/vps-git-backup/restic-password  repository password (keep an offline copy)
#
# DRY_RUN=1 prints the decision and the planned commands without calling restic.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a

log() { echo "offsite-backup: $*"; }
run() { if [ -n "${DRY_RUN:-}" ]; then log "would run: $*"; else "$@"; fi; }

if [ "${ROLE:-}" != primary ]; then
  log "role is ${ROLE:-unset}, not serving, skipping"; exit 0
fi
if [ "$(docker inspect -f '{{.State.Running}}' vps-git-forgejo 2>/dev/null)" != true ]; then
  log "forgejo is not running here (fenced or stopped), not serving, skipping"; exit 0
fi

SECRETS=/etc/vps-git-backup
set -a; . "$SECRETS/r2.env"; set +a
export RESTIC_PASSWORD_FILE="$SECRETS/restic-password"
HOST_TAG=(--host bts-forgejo)

data=$(docker volume inspect stack_forgejo_data -f '{{.Mountpoint}}')
# Fixed path so every snapshot restores the dump to the same place.
dump_dir=/var/tmp/vps-git-backup
dump=$dump_dir/forgejo-pg.dump
install -d -m 700 "$dump_dir"
trap 'rm -f "$dump"' EXIT

log "serving primary, backing up to $RESTIC_REPOSITORY"
run sh -c "docker exec vps-git-postgres pg_dump -U '$POSTGRES_USER' -d '$POSTGRES_DB' -Fc > '$dump'"
run restic backup "${HOST_TAG[@]}" --tag forgejo "$dump" "$data"
run restic forget "${HOST_TAG[@]}" --keep-daily 30 --keep-monthly 12 --prune
if [ "$(date -u +%u)" = 7 ]; then
  run restic check --read-data-subset 5%
fi
log "done"
