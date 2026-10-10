# Discord cards for the vps-git scripts, in the same style as GitNotify and Karmafeed:
# Components V2 (flags 32768), one container with an accent colour, a heading, fields,
# optional sections after a divider, a small grey footer and a row of link buttons.
#
#   . ./notify.sh
#   notify_card <kind> <title> <description> [Key=value ...] [section:<markdown>] [button:<label>|<https url>]
#
#   kind: ok (green), fail (red), warn (amber), info (blurple)
#
# Reads DISCORD_WEBHOOK_URL from /etc/forgejo-backup/notify.env (NOTIFY_ENV overrides
# the path). Without the file or the variable it does nothing. It never fails the
# caller: a slow or broken webhook must not break the job that posts. Text is ours
# (host names, restic output); anything that could carry Markdown goes in a code block.
notify_card() {
  local env_file=${NOTIFY_ENV:-/etc/forgejo-backup/notify.env} url payload
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
# The message id is STATUS_MESSAGE_ID in notify.env; create it once with
# `status-card.sh --create`. Only the node running Forgejo edits it. Needs .env loaded.
#
#   status_card_update           gather state and PATCH the card
#   status_card_payload          print the card JSON (used by --create and tests)
#
# Backup results come from the nightly backup job on the host (a restic job outside this repo):
# $BACKUP_STATE_DIR/last-<dest>.json for each destination in BACKUP_DESTS, and the
# next run from BACKUP_TIMER. Optional lines: "Watchdog" when WATCHDOG_URL is set in
# .env (any 2xx/3xx counts as reachable), "Runners" when FORGEJO_STATUS_TOKEN
# (read:admin) is in notify.env, and an "Uptime Kuma" button when STATUS_URL is set.
# watchdog_http_code: HTTP status of WATCHDOG_URL, "" when unset, 000 when unreachable.
watchdog_http_code() {
  [ -n "${WATCHDOG_URL:-}" ] || return 0
  curl -s -o /dev/null --max-time 10 -w '%{http_code}' "$WATCHDOG_URL" || true
}

status_card_payload() {
  local state_dir=${BACKUP_STATE_DIR:-/var/lib/forgejo-backup} version healthz next disk
  local watchdog runners token
  version=$(docker exec -u git vps-git-forgejo forgejo --version 2>/dev/null | awk '{print $3}' | cut -d+ -f1 || true)
  healthz=$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' "${APP_URL:-https://git.h1n054ur.dev}/api/healthz" || true)
  next=$(systemctl show -p NextElapseUSecRealtime --value "${BACKUP_TIMER:-forgejo-backup.timer}" 2>/dev/null || true)
  if [ -n "$next" ]; then next=$(date -d "$next" +%s 2>/dev/null || true); fi
  disk=$(df -h --output=used,size,pcent / 2>/dev/null | tail -1 | awk '{print $1 " / " $2 " (" $3 ")"}' || true)
  watchdog=$(watchdog_http_code)
  token=$(sed -n 's/^FORGEJO_STATUS_TOKEN=//p' "${NOTIFY_ENV:-/etc/forgejo-backup/notify.env}" 2>/dev/null | tail -1 || true)
  runners=""
  if [ -n "$token" ]; then
    runners=$(curl -s --max-time 10 -H "Authorization: token $token" \
      "http://127.0.0.1:3000/api/v1/admin/actions/runners" 2>/dev/null || true)
  fi
  python3 - "$(hostname)" "${version:-?}" "${healthz:-000}" "$state_dir" "${BACKUP_DESTS:-r2 rustfs}" \
    "$next" "$disk" "${APP_URL:-https://git.h1n054ur.dev}" \
    "${STATUS_URL:-}" \
    "${WATCHDOG_URL:-}" "$watchdog" "$runners" <<'PY'
import json, sys, time
(host, version, healthz, state_dir, dests, next_run, disk, app_url, status_url,
 watchdog_url, watchdog, runners_raw) = sys.argv[1:]
problems, warnings = [], []
if healthz != "200":
    problems.append(f"public healthz {healthz}")
backup_lines = []
for dest in dests.split():
    try:
        backup = json.load(open(f"{state_dir}/last-{dest}.json"))
    except (OSError, ValueError):
        backup = None
    if not backup:
        warnings.append(f"no {dest} backup recorded yet")
        backup_lines.append(f"**Backup {dest}:** none recorded yet")
        continue
    when = f"<t:{int(backup.get('time', 0))}:R>"
    if backup.get("result") == "ok":
        if time.time() - backup.get("time", 0) > 26 * 3600:
            warnings.append(f"{dest} backup older than 26 h")
        backup_lines.append(f"**Backup {dest}:** ✅ {when} · snapshot `{backup.get('snapshot', '?')}` · {backup.get('size', '?')}")
    else:
        problems.append(f"{dest} backup failed at {backup.get('step', '?')}")
        backup_lines.append(f"**Backup {dest}:** \U0001F6A8 {when} · failed at **{backup.get('step', '?')}**")
watchdog_line = ""
if watchdog_url:
    if watchdog[:1] in ("2", "3"):
        watchdog_line = "**Watchdog:** reachable"
    else:
        watchdog_line = f"**Watchdog:** \U0001F6A8 unreachable (HTTP {watchdog or '000'}), Uptime Kuma alerts are silent"
        warnings.append("watchdog unreachable")
runners_line = ""
if runners_raw:
    try:
        runners = json.loads(runners_raw)
        runners = runners.get("runners", runners) if isinstance(runners, dict) else runners
        names = [f"{r.get('name', '?')} {r.get('status', '?')}" for r in runners]
        offline = [r.get("name", "?") for r in runners if r.get("status") == "offline"]
        runners_line = f"**Runners:** {len(runners) - len(offline)}/{len(runners)} online · " + ", ".join(names)
        if offline:
            warnings.append("runner offline: " + ", ".join(offline))
    except ValueError:
        runners_line = "**Runners:** unknown (API error)"
if problems:
    accent, overall = 0x7F1D1D, "\U0001F6A8 **Failure:** " + ", ".join(problems + warnings)
elif warnings:
    accent, overall = 0xF59E0B, "⚠️ **Degraded:** " + ", ".join(warnings)
else:
    accent, overall = 0x22C55E, "✅ **All systems normal**"
next_line = f"**Next backup:** <t:{next_run}:R>" if next_run else "**Next backup:** not scheduled"
divider = {"type": 14, "divider": True, "spacing": 1}
parts = [
    {"type": 10, "content": f"### \U0001F5A5️ vps-git status\n{overall}"},
    divider,
    {"type": 10, "content": "\n".join(x for x in (
        f"**Forgejo:** single instance on `{host}` · v{version} · public healthz {healthz}",
        watchdog_line, runners_line) if x)},
    divider,
    {"type": 10, "content": "\n".join(backup_lines + [next_line, f"**Disk ({host}):** {disk}"])},
    {"type": 10, "content": f"-# updated <t:{int(time.time())}:R> by {host}"},
    divider,
    {"type": 1, "components": [
        {"type": 2, "style": 5, "label": "Open Forgejo", "url": app_url},
    ] + ([{"type": 2, "style": 5, "label": "Uptime Kuma", "url": status_url}] if status_url.startswith("https://") else [])},
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
    env_file=${NOTIFY_ENV:-/etc/forgejo-backup/notify.env}
    [ -r "$env_file" ] || exit 0
    url=$(sed -n 's/^DISCORD_WEBHOOK_URL=//p' "$env_file" | tail -1)
    mid=$(sed -n 's/^STATUS_MESSAGE_ID=//p' "$env_file" | tail -1)
    [ -n "$url" ] && [ -n "$mid" ] || exit 0
    [ "$(docker inspect -f '{{.State.Running}}' vps-git-forgejo 2>/dev/null)" = true ] || exit 0
    payload=$(status_card_payload) || exit 0
    # An edit keeps the message's flags; send only what changes.
    payload=$(printf '%s' "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.pop("flags"); d.pop("username"); print(json.dumps(d))') || exit 0
    curl -fsS --max-time 10 -X PATCH -H 'Content-Type: application/json' -d "$payload" \
      "${url}/messages/${mid}?with_components=true" >/dev/null 2>&1
  ) || true
}
