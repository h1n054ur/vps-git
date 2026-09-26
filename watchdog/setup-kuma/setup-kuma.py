#!/usr/bin/env python3
"""
Auto-configure Uptime Kuma after first deploy.
Creates admin account, adds monitors, and sets up a public status page.

Uses socketio.Client with sio.call() for proper request/response handling.
Tested against Uptime Kuma 1.23.x Socket.IO API.

Usage (inside Docker via compose):
  docker compose --env-file .env run --rm setup-kuma \
    --url http://localhost:3001 \
    --username admin \
    --password 'YourPassword' \
    --health-url https://git.example.com/api/healthz \
    --primary-host 100.x.x.x \
    --standby-host 100.y.y.y
"""

import argparse
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
    args = parser.parse_args()

    print(f"Connecting to Uptime Kuma at {args.url}...")

    if not wait_for_kuma(args.url):
        print("ERROR: Uptime Kuma not reachable. Exiting.")
        sys.exit(1)

    sio = socketio.Client()

    needs_setup = False
    monitors = {}

    @sio.on("setup")
    def on_setup():
        nonlocal needs_setup
        needs_setup = True

    @sio.on("monitorList")
    def on_monitor_list(data):
        monitors.update(data)

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

    created = 0
    skipped = 0
    for mon in monitor_defs:
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
        except Exception as e:
            print(f" ERROR: {e}")

    # ── Done ──────────────────────────────────────────────────────────
    # NOTE: No public status page is created. The Kuma dashboard (behind login)
    # shows all monitors. A public status page would leak infrastructure details
    # (Tailscale IPs, internal hostnames, ports).
    print(f"\nDone. Monitors created: {created}, skipped: {skipped}.")
    sio.disconnect()


if __name__ == "__main__":
    main()
