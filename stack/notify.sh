# Discord cards for the vps-git scripts, in the same style as GitNotify and Karmafeed:
# Components V2 (flags 32768), one container with an accent colour, a heading, fields,
# optional sections after a divider, a small grey footer and a row of link buttons.
#
#   . ./notify.sh
#   notify_card <kind> <title> <description> [Key=value ...] [section:<markdown>] [button:<label>|<https url>]
#
#   kind: ok (green), fail (red), warn (amber), fence (amber), info (blurple)
#
# Reads DISCORD_WEBHOOK_URL from /etc/vps-git-backup/notify.env (NOTIFY_ENV overrides
# the path). Without the file or the variable it does nothing. It never fails the
# caller: a slow or broken webhook must not break a backup or the fence. Text is ours
# (host names, restic output); anything that could carry Markdown goes in a code block.
notify_card() {
  local env_file=${NOTIFY_ENV:-/etc/vps-git-backup/notify.env} url payload
  [ -r "$env_file" ] || return 0
  url=$(sed -n 's/^DISCORD_WEBHOOK_URL=//p' "$env_file" | tail -1)
  [ -n "$url" ] || return 0
  payload=$(python3 - "$(hostname)" "$@" <<'PY' 2>/dev/null
import json, sys, time
host, kind, title, desc, *rest = sys.argv[1:]
style = {
    "ok": (0x22C55E, "✅"),
    "fail": (0x7F1D1D, "\U0001F6A8"),
    "warn": (0xF59E0B, "⚠️"),
    "fence": (0xF59E0B, "\U0001F6E1️"),
    "info": (0x5865F2, "ℹ️"),
}
accent, emoji = style.get(kind, style["info"])
fields, sections, buttons = [], [], []
for arg in rest:
    if arg.startswith("section:"):
        sections.append(arg[len("section:"):])
    elif arg.startswith("button:") and "|" in arg:
        label, link = arg[len("button:"):].split("|", 1)
        if link.startswith("https://"):
            buttons.append({"type": 2, "style": 5, "label": label[:80], "url": link})
    elif "=" in arg:
        key, value = arg.split("=", 1)
        fields.append(f"**{key}:** {value}")
head = "\n".join([f"### {emoji} {title}", desc, *([""] + fields if fields else [])]).strip()
parts = [{"type": 10, "content": head[:1500]}]
for section in sections:
    parts += [{"type": 14, "divider": True, "spacing": 1}, {"type": 10, "content": section[:1500]}]
parts.append({"type": 10, "content": f"-# vps-git · {host} · <t:{int(time.time())}:f>"})
if buttons:
    parts += [{"type": 14, "divider": True, "spacing": 1}, {"type": 1, "components": buttons[:5]}]
print(json.dumps({
    "username": "vps-git",
    "flags": 1 << 15,
    "allowed_mentions": {"parse": []},
    "components": [{"type": 17, "accent_color": accent, "components": parts}],
}))
PY
) || return 0
  # A webhook ignores components unless asked to respect them.
  curl -fsS --max-time 10 -H 'Content-Type: application/json' -d "$payload" "${url}?with_components=true" >/dev/null 2>&1 || true
}

# One live "vps-git status" card, edited in place instead of posting new messages.
# The message id is STATUS_MESSAGE_ID in notify.env (both nodes share it); create it
# once with `status-card.sh --create`. Only the serving primary (ROLE=primary and
# Forgejo running) edits it, so there is a single writer. Needs .env to be loaded.
#
#   status_card_update           gather state and PATCH the card
#   status_card_payload          print the card JSON (used by --create and tests)
#
# Backup results come from /var/lib/vps-git/last-backup.json (offsite-backup.sh), the
# fence decision from /var/lib/vps-git/fence.state and fence.reason (fence.sh).
status_card_payload() {
  local state_dir=${VPS_GIT_STATE:-/var/lib/vps-git} version healthz repl peer_ok next disk
  version=$(docker exec -u git vps-git-forgejo forgejo --version 2>/dev/null | awk '{print $3}' | cut -d+ -f1 || true)
  healthz=$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' "${APP_URL:-https://git.h1n054ur.dev}/api/healthz" || true)
  repl=$(docker exec vps-git-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc \
    "select state || '|' || coalesce(extract(epoch from replay_lag)::int::text, '0') from pg_stat_replication limit 1" 2>/dev/null || true)
  peer_ok=unknown
  if [ -n "${PEER_HOST:-}" ]; then
    docker exec vps-git-postgres pg_isready -q -t 5 -h "$PEER_HOST" >/dev/null 2>&1 && peer_ok=yes || peer_ok=no
  fi
  next=$(systemctl show -p NextElapseUSecRealtime --value vps-git-offsite-backup.timer 2>/dev/null || true)
  if [ -n "$next" ]; then next=$(date -d "$next" +%s 2>/dev/null || true); fi
  disk=$(df -h --output=used,size,pcent / 2>/dev/null | tail -1 | awk '{print $1 " / " $2 " (" $3 ")"}' || true)
  python3 - "$(hostname)" "${version:-?}" "${healthz:-000}" "$repl" "$peer_ok" "${PEER_HOST:-}" \
    "$(cat "$state_dir/fence.state" 2>/dev/null)" "$(cat "$state_dir/fence.reason" 2>/dev/null)" \
    "$state_dir/last-backup.json" "$next" "$disk" \
    "${APP_URL:-https://git.h1n054ur.dev}" "${STATUS_URL:-https://status-git.h1n054ur.dev}" <<'PY'
import json, sys, time
(host, version, healthz, repl, peer_ok, peer, fence, fence_reason, backup_file,
 next_run, disk, app_url, status_url) = sys.argv[1:]
problems, warnings = [], []
if healthz != "200":
    problems.append(f"public healthz {healthz}")
state, _, lag = repl.partition("|")
if state != "streaming":
    warnings.append("no streaming standby")
if peer and peer_ok != "yes":
    warnings.append("peer Postgres unreachable")
try:
    backup = json.load(open(backup_file))
except (OSError, ValueError):
    backup = None
if backup and backup.get("result") != "ok":
    problems.append(f"last backup failed at {backup.get('step', '?')}")
elif not backup:
    warnings.append("no backup recorded yet")
if problems:
    accent, overall = 0x7F1D1D, "\U0001F6A8 **Failure:** " + ", ".join(problems + warnings)
elif warnings:
    accent, overall = 0xF59E0B, "⚠️ **Degraded:** " + ", ".join(warnings)
else:
    accent, overall = 0x22C55E, "✅ **All systems normal**"
repl_line = (f"**Replication:** {state}, replay lag {lag or 0}s" if state
             else "**Replication:** no standby connected")
peer_line = {"yes": "reachable", "no": "unreachable"}.get(peer_ok, "unknown")
fence_line = f"**Fence:** {fence or '?'}" + (f" ({fence_reason})" if fence_reason else "")
if peer:
    fence_line += f" · peer `{peer}` {peer_line}"
if backup:
    mark = "✅" if backup.get("result") == "ok" else "\U0001F6A8"
    bits = [f"<t:{int(backup.get('time', 0))}:R>"]
    if backup.get("result") == "ok":
        bits += [f"snapshot `{backup.get('snapshot', '?')}`", backup.get("size", "?"), f"{backup.get('duration', '?')}s"]
    else:
        bits += [f"failed at **{backup.get('step', '?')}**"]
    backup_line = f"**Last backup:** {mark} " + " · ".join(bits)
else:
    backup_line = "**Last backup:** none recorded yet"
next_line = f"**Next backup:** <t:{next_run}:R>" if next_run else "**Next backup:** not scheduled"
divider = {"type": 14, "divider": True, "spacing": 1}
parts = [
    {"type": 10, "content": f"### \U0001F5A5️ vps-git status\n{overall}"},
    divider,
    {"type": 10, "content": f"**Forgejo:** serving on `{host}` · v{version} · public healthz {healthz}\n{repl_line}\n{fence_line}"},
    divider,
    {"type": 10, "content": f"{backup_line}\n{next_line}\n**Disk ({host}):** {disk}"},
    {"type": 10, "content": f"-# updated <t:{int(time.time())}:R> by {host}"},
    divider,
    {"type": 1, "components": [
        {"type": 2, "style": 5, "label": "Open Forgejo", "url": app_url},
        {"type": 2, "style": 5, "label": "Status page", "url": status_url},
    ]},
]
print(json.dumps({
    "username": "vps-git",
    "flags": 1 << 15,
    "allowed_mentions": {"parse": []},
    "components": [{"type": 17, "accent_color": accent, "components": parts}],
}))
PY
}

status_card_update() {
  (
    env_file=${NOTIFY_ENV:-/etc/vps-git-backup/notify.env}
    [ -r "$env_file" ] || exit 0
    url=$(sed -n 's/^DISCORD_WEBHOOK_URL=//p' "$env_file" | tail -1)
    mid=$(sed -n 's/^STATUS_MESSAGE_ID=//p' "$env_file" | tail -1)
    [ -n "$url" ] && [ -n "$mid" ] || exit 0
    [ "${ROLE:-}" = primary ] || exit 0
    [ "$(docker inspect -f '{{.State.Running}}' vps-git-forgejo 2>/dev/null)" = true ] || exit 0
    payload=$(status_card_payload) || exit 0
    # An edit keeps the message's flags; send only what changes.
    payload=$(printf '%s' "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.pop("flags"); d.pop("username"); print(json.dumps(d))') || exit 0
    curl -fsS --max-time 10 -X PATCH -H 'Content-Type: application/json' -d "$payload" \
      "${url}/messages/${mid}?with_components=true" >/dev/null 2>&1
  ) || true
}
