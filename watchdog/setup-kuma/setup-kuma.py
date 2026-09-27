#!/usr/bin/env python3
"""
Auto-configure Uptime Kuma after first deploy.
Creates the admin account, adds the monitors and, optionally, the Discord card
notification. No public status page is created (see the note at the end).

Uses socketio.Client with sio.call() for proper request/response handling.
Tested against the Uptime Kuma 2.x Socket.IO API.

Usage (inside Docker via compose):
  docker compose --env-file .env run --rm setup-kuma \
    --url http://localhost:3001 \
    --username admin \
    --password 'YourPassword' \
    --health-url https://git.example.com/api/healthz \
    --primary-host 100.x.x.x \
    --standby-host 100.y.y.y \
    --discord-webhook https://discord.com/api/webhooks/...   # optional
"""

import argparse
import os
import sys
import time
import urllib.request

try:
    import socketio
except ImportError:
    print("ERROR: python-socketio[client] required. Install: pip install 'python-socketio[client]'")
    sys.exit(1)


def wait_for_kuma(url, retries=30, delay=5):
    """Wait for Uptime Kuma to be ready."""
    for i in range(retries):
        try:
            req = urllib.request.urlopen(url, timeout=5)
            if req.status == 200:
                return True
        except Exception:
            pass
        print(f"Waiting for Uptime Kuma ({i+1}/{retries})...")
        time.sleep(delay)
    return False


def main():
    parser = argparse.ArgumentParser(description="Auto-configure Uptime Kuma monitors")
    parser.add_argument("--url", required=True, help="Uptime Kuma URL (e.g. http://localhost:3001)")
    parser.add_argument("--username", required=True, help="Admin username to create")
    parser.add_argument("--password", required=True, help="Admin password")
    parser.add_argument("--health-url", required=True, help="Forgejo health endpoint URL")
    parser.add_argument("--primary-host", required=True, help="Primary VPS IP (Tailscale/private)")
    parser.add_argument("--standby-host", required=True, help="Standby VPS IP (Tailscale/private)")
    parser.add_argument("--discord-webhook", default="", help="Optional Discord webhook URL; creates a default notification attached to every monitor")
    parser.add_argument("--discord-name", default="Discord #forgejo", help="Name of the Discord notification in Kuma")
    parser.add_argument("--test-notification", action="store_true", help="Send a test message through the Discord notification")
    parser.add_argument("--extra-host", action="append", default=[], metavar="NAME=HOST",
                        help="Also monitor another machine (repeatable): adds '<NAME> - Ping' and '<NAME> - SSH'")
    args = parser.parse_args()

    print(f"Connecting to Uptime Kuma at {args.url}...")

    if not wait_for_kuma(args.url):
        print("ERROR: Uptime Kuma not reachable. Exiting.")
        sys.exit(1)

    sio = socketio.Client()

    needs_setup = False
    monitors = {}
    notifications = []

    @sio.on("setup")
    def on_setup():
        nonlocal needs_setup
        needs_setup = True

    @sio.on("monitorList")
    def on_monitor_list(data):
        monitors.update(data)

    @sio.on("notificationList")
    def on_notification_list(data):
        notifications[:] = data

    sio.connect(args.url)
    time.sleep(2)  # let initial events arrive

    # ── Step 1: Initial setup (create admin account) ──────────────────
    if needs_setup:
        print("Kuma needs initial setup. Creating admin account...")
        # setup takes (username, password) as two positional args
        resp = sio.call("setup", data=(args.username, args.password), timeout=10)
        if resp.get("ok"):
            print(f"  Admin account created: {args.username}")
        else:
            print(f"  Setup failed: {resp.get('msg', 'unknown error')}")
            sio.disconnect()
            sys.exit(1)
    else:
        print("Kuma already set up.")

    # ── Step 2: Login ─────────────────────────────────────────────────
    print("Logging in...")
    resp = sio.call("login", data={
        "username": args.username,
        "password": args.password,
        "token": "",
    }, timeout=10)

    if not resp.get("ok"):
        print(f"  Login failed: {resp.get('msg', 'unknown error')}")
        sio.disconnect()
        sys.exit(1)

    print("  Logged in.")
    time.sleep(2)  # let monitorList arrive

    # ── Step 3: Check existing monitors ───────────────────────────────
    existing_names = {m["name"] for m in monitors.values()}
    print(f"Existing monitors: {sorted(existing_names) if existing_names else 'none'}")

    # ── Step 4: Create monitors ───────────────────────────────────────
    monitor_defs = [
        {
            "name": "Forgejo Health",
            "type": "http",
            "url": args.health_url,
            "method": "GET",
            "interval": 30,
            "retryInterval": 30,
            "maxretries": 3,
            "accepted_statuscodes": ["200-299"],
            "active": True,
            "notificationIDList": [],
        },
        {
            "name": "Forgejo Web",
            "type": "http",
            "url": args.health_url.replace("/api/healthz", ""),
            "method": "GET",
            "interval": 60,
            "retryInterval": 60,
            "maxretries": 3,
            "accepted_statuscodes": ["200-399"],
            "active": True,
            "notificationIDList": [],
        },
        {
            "name": "Primary - Postgres",
            "type": "port",
            "hostname": args.primary_host,
            "port": 5432,
            "interval": 30,
            "retryInterval": 30,
            "maxretries": 3,
            "accepted_statuscodes": ["200-299"],
            "active": True,
            "notificationIDList": [],
        },
        {
            "name": "Primary - SSH",
            "type": "port",
            "hostname": args.primary_host,
            "port": 22,
            "interval": 60,
            "retryInterval": 60,
            "maxretries": 3,
            "accepted_statuscodes": ["200-299"],
            "active": True,
            "notificationIDList": [],
        },
        {
            "name": "Standby - Postgres",
            "type": "port",
            "hostname": args.standby_host,
            "port": 5432,
            "interval": 30,
            "retryInterval": 30,
            "maxretries": 3,
            "accepted_statuscodes": ["200-299"],
            "active": True,
            "notificationIDList": [],
        },
        {
            "name": "Standby - SSH",
            "type": "port",
            "hostname": args.standby_host,
            "port": 22,
            "interval": 60,
            "retryInterval": 60,
            "maxretries": 3,
            "accepted_statuscodes": ["200-299"],
            "active": True,
            "notificationIDList": [],
        },
    ]
    for spec in args.extra_host:
        name, _, host = spec.partition("=")
        if not name or not host:
            print(f"  SKIP: bad --extra-host {spec!r} (want NAME=HOST)")
            continue
        monitor_defs += [
            {"name": f"{name} - Ping", "type": "ping", "hostname": host, "interval": 60,
             "retryInterval": 60, "maxretries": 3, "accepted_statuscodes": ["200-299"],
             "active": True, "notificationIDList": []},
            {"name": f"{name} - SSH", "type": "port", "hostname": host, "port": 22, "interval": 60,
             "retryInterval": 60, "maxretries": 3, "accepted_statuscodes": ["200-299"],
             "active": True, "notificationIDList": []},
        ]

    # Fields Uptime Kuma 2 requires on every monitor (it rejects NULL conditions).
    kuma2_defaults = {
        "conditions": "[]",
        "kafkaProducerBrokers": [],
        "kafkaProducerSaslOptions": {},
        "rabbitmqNodes": [],
    }
    created = 0
    skipped = 0
    failed = 0
    for mon in monitor_defs:
        mon = {**kuma2_defaults, **mon}
        if mon["name"] in existing_names:
            print(f"  SKIP: {mon['name']} (already exists)")
            skipped += 1
            continue

        print(f"  ADD:  {mon['name']}...", end="", flush=True)
        try:
            resp = sio.call("add", data=mon, timeout=10)
            if resp.get("ok"):
                print(f" OK (id={resp.get('monitorID')})")
                created += 1
            else:
                print(f" FAIL: {resp.get('msg', 'unknown')}")
                failed += 1
        except Exception as e:
            print(f" ERROR: {e}")
            failed += 1

    # ── Step 5: Discord notification (optional) ───────────────────────
    # Kuma's own Discord provider only sends basic embeds, so this uses the
    # Webhook provider with a Liquid template (discord-card.liquid) that posts a
    # Components V2 card in the same style as GitNotify: accent colour by status
    # (green up, red down, amber pending), target, error or response time,
    # Discord timestamps, and link buttons to the status page and the target. isDefault attaches it to
    # monitors created later; applyExisting attaches it to every monitor now.
    # Idempotent: an existing notification with the same name is updated.
    if args.discord_webhook:
        time.sleep(1)  # let notificationList arrive
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "discord-card.liquid")) as f:
            card_template = f.read()
        existing = next((n for n in notifications if n.get("name") == args.discord_name), None)
        sep = "&" if "?" in args.discord_webhook else "?"
        notif = {
            "name": args.discord_name,
            "type": "webhook",
            "isDefault": True,
            "applyExisting": True,
            # with_components lets a plain (non-bot) webhook post Components V2
            "webhookURL": args.discord_webhook + sep + "with_components=true",
            "webhookContentType": "custom",
            "webhookCustomBody": card_template,
            "webhookAdditionalHeaders": '{"Content-Type": "application/json"}',
        }
        notif_id = existing["id"] if existing else None
        print(f"  {'UPDATE' if existing else 'ADD'}:  notification {args.discord_name}...", end="", flush=True)
        resp = sio.call("addNotification", data=(notif, notif_id), timeout=10)
        print(f" {'OK' if resp.get('ok') else 'FAIL: ' + str(resp.get('msg'))} (id={resp.get('id', notif_id)})")
        if args.test_notification:
            resp = sio.call("testNotification", data=notif, timeout=15)
            print(f"  TEST: {'sent' if resp.get('ok') else 'FAIL: ' + str(resp.get('msg'))}")

    # ── Done ──────────────────────────────────────────────────────────
    # NOTE: No public status page is created. The Kuma dashboard (behind login)
    # shows all monitors. A public status page would leak infrastructure details
    # (Tailscale IPs, internal hostnames, ports).
    print(f"\nDone. Monitors created: {created}, skipped: {skipped}, failed: {failed}.")
    sio.disconnect()
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
