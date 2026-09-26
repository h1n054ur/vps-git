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
# Each run records its result in /var/lib/vps-git/last-backup.json and refreshes the
# live status card (notify.sh). A failure also posts a separate alert card with the
# failed step and its last error line. A standby or fenced node posts nothing.
#
# DRY_RUN=1 prints the decision and the planned commands without calling restic
# or posting. VPS_GIT_SECRETS points at a different secrets dir (for testing).
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a
. ./notify.sh

log() { echo "offsite-backup: $*"; }
run() { if [ -n "${DRY_RUN:-}" ]; then log "would run: $*"; else "$@"; fi; }

if [ "${ROLE:-}" != primary ]; then
  log "role is ${ROLE:-unset}, not serving, skipping"; exit 0
fi
if [ "$(docker inspect -f '{{.State.Running}}' vps-git-forgejo 2>/dev/null)" != true ]; then
  log "forgejo is not running here (fenced or stopped), not serving, skipping"; exit 0
fi

# Fixed path so every snapshot restores the dump to the same place.
dump_dir=/var/tmp/vps-git-backup
dump=$dump_dir/forgejo-pg.dump
out=$dump_dir/last-run.log
install -d -m 700 "$dump_dir"
install -m 600 /dev/null "$out"
started=$(date +%s)
current_step="setup"
state_dir=${VPS_GIT_STATE:-/var/lib/vps-git}
record() {  # record <result> [key value ...]
  install -d -m 755 "$state_dir"
  python3 - "$state_dir/last-backup.json" "$@" <<'PY'
import json, sys, time
path, result, *kv = sys.argv[1:]
data = {"time": int(time.time()), "result": result}
data.update(dict(zip(kv[::2], kv[1::2])))
json.dump(data, open(path, "w"))
PY
}
finish() {
  local rc=$?
  rm -f "$dump"
  if [ "$rc" -ne 0 ] && [ -z "${DRY_RUN:-}" ]; then
    local why
    why=$(grep -iE 'fatal|error' "$out" | tail -1)
    [ -n "$why" ] || why=$(grep -v '^[[:space:]]*$' "$out" | tail -1)
    notify_card fail "Offsite backup failed" "The nightly backup to R2 stopped at **$current_step**." \
      "Host=$(hostname)" "Step=$current_step" "Exit code=$rc" \
      "section:**Last error**
\`\`\`
$(printf '%s' "${why:-exit $rc}" | tr -d '`' | cut -c1-900)
\`\`\`
-# Full output: \`journalctl -u vps-git-offsite-backup\`" \
      "button:Open Forgejo|${APP_URL:-https://git.h1n054ur.dev}" "button:Status page|${STATUS_URL:-https://status-git.h1n054ur.dev}"
    record failed step "$current_step" error "$(printf '%s' "${why:-exit $rc}" | cut -c1-300)" || true
    status_card_update
  fi
  exit "$rc"
}
trap finish EXIT
# Capture every step's output so a failure can report its step and last line.
step() { current_step=$1; shift; run "$@" 2>&1 | tee -a "$out"; }

SECRETS=${VPS_GIT_SECRETS:-/etc/vps-git-backup}
set -a; . "$SECRETS/r2.env"; set +a
export RESTIC_PASSWORD_FILE="$SECRETS/restic-password"
HOST_TAG=(--host bts-forgejo)

data=$(docker volume inspect stack_forgejo_data -f '{{.Mountpoint}}')

log "serving primary, backing up to $RESTIC_REPOSITORY"
step "pg_dump" sh -c "docker exec vps-git-postgres pg_dump -U '$POSTGRES_USER' -d '$POSTGRES_DB' -Fc > '$dump'"
step "restic backup" restic backup "${HOST_TAG[@]}" --tag forgejo "$dump" "$data"
step "restic forget" restic forget "${HOST_TAG[@]}" --keep-daily 30 --keep-monthly 12 --prune
if [ "$(date -u +%u)" = 7 ]; then
  step "restic check" restic check --read-data-subset 5%
fi
log "done"
if [ -z "${DRY_RUN:-}" ]; then
  snap=$(sed -n 's/^snapshot \([0-9a-f]*\) saved$/\1/p' "$out" | tail -1)
  files=$(sed -n 's/^processed \([0-9]*\) files, .*/\1/p' "$out" | tail -1)
  size=$(sed -n 's/^processed [0-9]* files, \(.*\) in .*/\1/p' "$out" | tail -1)
  record ok snapshot "${snap:-?}" size "${size:-?}" files "${files:-?}" duration "$(( $(date +%s) - started ))"
  status_card_update
fi
