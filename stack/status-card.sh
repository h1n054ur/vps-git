#!/usr/bin/env bash
# Refresh the live "vps-git status" card in Discord (see status_card_update in
# notify.sh). Run by vps-git-status.timer every 15 minutes; only the serving
# primary edits the card. When WATCHDOG_URL is set it also watches the watchdog:
# one alert card when it becomes unreachable (Uptime Kuma alerts would be silent)
# and one card when it recovers; the last state is kept in watchdog.state.
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

# Watch the watchdog (serving primary only, so one node reports).
if [ -n "${WATCHDOG_URL:-}" ] && [ "${ROLE:-}" = primary ] &&
   [ "$(docker inspect -f '{{.State.Running}}' vps-git-forgejo 2>/dev/null)" = true ]; then
  state_file=${VPS_GIT_STATE:-/var/lib/vps-git}/watchdog.state
  code=$(watchdog_http_code)
  case $code in 2*|3*) now=reachable ;; *) now=unreachable ;; esac
  before=$(cat "$state_file" 2>/dev/null || true)
  if [ "$now" != "$before" ]; then
    if [ "$now" = unreachable ]; then
      notify_card fail "Watchdog unreachable" "Uptime Kuma alerts are silent until the watchdog is back." \
        "Checked from=$(hostname)" "URL=$WATCHDOG_URL" "HTTP=${code:-000}" \
        "button:Status page|${STATUS_URL:-https://status-git.h1n054ur.dev}" "button:Open Forgejo|${APP_URL:-https://git.h1n054ur.dev}"
    elif [ -n "$before" ]; then
      notify_card ok "Watchdog reachable again" "Uptime Kuma is back and alerting." \
        "Checked from=$(hostname)" "URL=$WATCHDOG_URL" "HTTP=$code" \
        "button:Status page|${STATUS_URL:-https://status-git.h1n054ur.dev}"
    fi
    mkdir -p "$(dirname "$state_file")"
    echo "$now" > "$state_file"
  fi
fi

status_card_update
