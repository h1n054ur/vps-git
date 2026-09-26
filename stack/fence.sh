#!/usr/bin/env bash
# Split-brain fence for a node configured as primary.
#
# Both nodes hold credentials for the same Cloudflare tunnel, so a node must only
# run Forgejo, cloudflared and the backup sidecar while it is the newest primary.
# Every promotion moves Postgres to a new timeline, so the node that took over
# last always has the higher timeline. This script compares timelines with the
# peer and starts or stops the serving containers accordingly.
#
#   peer unreachable                  -> serve (standby down is normal)
#   peer is a standby                 -> serve
#   peer is a primary, lower timeline -> serve (the peer fences itself)
#   anything else                     -> fence (stop forgejo, cloudflared, backup)
#
# Run by vps-git-fence.timer at boot and every minute. DRY_RUN=1 prints the
# decision without acting. Standby nodes exit immediately.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a

log() { echo "fence: $*"; }
compose() { docker compose --env-file .env "$@"; }

if [ "${ROLE:-}" != primary ]; then
  log "role is ${ROLE:-unset}, nothing to do"; exit 0
fi

# Postgres has to be up to read our own timeline; it never serves traffic itself.
[ -n "${DRY_RUN:-}" ] || compose up -d postgres >/dev/null 2>&1
for _ in $(seq 1 30); do
  docker exec vps-git-postgres pg_isready -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" && break
  sleep 2
done

sql() {  # sql <host or empty for local> <query>
  local host=()
  [ -n "$1" ] && host=(-h "$1")
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -e PGCONNECT_TIMEOUT=5 vps-git-postgres \
    psql "${host[@]}" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "$2" 2>/dev/null
}
STATE_SQL="select pg_is_in_recovery()::text || ' ' || timeline_id || ' ' || system_identifier from pg_control_checkpoint(), pg_control_system()"

read -r _ my_tl my_sys <<< "$(sql "" "$STATE_SQL")" || true
if [ -z "${my_tl:-}" ]; then
  log "cannot read local timeline, fencing to be safe"; decision=fence
elif [ -z "${PEER_HOST:-}" ]; then
  decision=serve; reason="no peer configured"
else
  peer=$(sql "$PEER_HOST" "$STATE_SQL" || true)
  if [ -z "$peer" ]; then
    decision=serve; reason="peer $PEER_HOST unreachable"
  else
    read -r peer_recovery peer_tl peer_sys <<< "$peer"
    if [ "$peer_sys" != "$my_sys" ]; then
      decision=fence; reason="peer is a different cluster (system id $peer_sys vs $my_sys)"
    elif [ "$peer_recovery" = true ]; then
      decision=serve; reason="peer is a standby"
    elif [ "$peer_tl" -lt "$my_tl" ]; then
      decision=serve; reason="peer is a stale primary (timeline $peer_tl < $my_tl)"
    else
      decision=fence; reason="peer is primary on timeline $peer_tl >= ours $my_tl"
    fi
  fi
fi

log "$decision: ${reason:-}"
[ -n "${DRY_RUN:-}" ] && exit 0
if [ "$decision" = serve ]; then
  compose up -d >/dev/null 2>&1
else
  compose stop forgejo cloudflared backup >/dev/null 2>&1 || true
fi
