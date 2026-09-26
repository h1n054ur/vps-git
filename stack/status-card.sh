#!/usr/bin/env bash
# Refresh the live "vps-git status" card in Discord (see status_card_update in
# notify.sh). Run by vps-git-status.timer every 15 minutes; only the serving
# primary edits the card.
#
#   status-card.sh            edit the card in place
#   status-card.sh --create   post a new card once and print its message id, to
#                             store as STATUS_MESSAGE_ID in notify.env on both nodes
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a
. ./notify.sh

if [ "${1:-}" = --create ]; then
  env_file=${NOTIFY_ENV:-/etc/vps-git-backup/notify.env}
  url=$(sed -n 's/^DISCORD_WEBHOOK_URL=//p' "$env_file" | tail -1)
  [ -n "$url" ] || { echo "status-card: no DISCORD_WEBHOOK_URL in $env_file" >&2; exit 1; }
  status_card_payload | curl -fsS --max-time 10 -H 'Content-Type: application/json' -d @- \
    "${url}?wait=true&with_components=true" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
  exit 0
fi
status_card_update
