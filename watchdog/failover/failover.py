#!/usr/bin/env python3
"""
Watchdog that monitors the primary Forgejo instance and triggers
automatic failover via Ansible when it detects sustained downtime.
"""

import os
import subprocess
import time
import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [watchdog] %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)

HEALTH_URL = os.environ["PRIMARY_HEALTH_URL"]
CHECK_INTERVAL = int(os.environ.get("CHECK_INTERVAL", 30))
FAIL_THRESHOLD = int(os.environ.get("FAIL_THRESHOLD", 3))
PLAYBOOK = os.environ.get("ANSIBLE_PLAYBOOK", "/ansible/promote.yml")
INVENTORY = os.environ.get("ANSIBLE_INVENTORY", "/ansible/inventory.yml")
COOLDOWN_SEC = int(os.environ.get("COOLDOWN_SEC", 3600))
# Outside endpoints that tell "the primary is down" apart from "the watchdog is offline".
# A round only counts as a failure when at least one of them answers.
INTERNET_CHECK_URLS = os.environ.get(
    "INTERNET_CHECK_URLS",
    "https://1.1.1.1/cdn-cgi/trace,https://www.google.com/generate_204",
).split(",")
DISCORD_WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "")

consecutive_failures = 0
last_failover: float = 0


def check_health() -> bool:
    try:
        import requests
        r = requests.get(HEALTH_URL, timeout=10)
        return r.status_code == 200
    except Exception as e:
        log.warning("Health check failed: %s", e)
        return False


def internet_ok() -> bool:
    """True when the watchdog itself can reach the internet."""
    import requests
    for url in INTERNET_CHECK_URLS:
        try:
            requests.get(url.strip(), timeout=5)
            return True
        except Exception:
            continue
    return False


def alert(message: str):
    """Best-effort Discord alert; never raises."""
    if not DISCORD_WEBHOOK_URL:
        return
    try:
        import requests
        requests.post(DISCORD_WEBHOOK_URL, json={"content": f"**vps-git watchdog:** {message}"}, timeout=10)
    except Exception as e:
        log.warning("Discord alert failed: %s", e)


def trigger_failover():
    global last_failover

    elapsed = time.time() - last_failover
    if last_failover > 0 and elapsed < COOLDOWN_SEC:
        log.warning("Cooldown active (%ds left). Skipping.", int(COOLDOWN_SEC - elapsed))
        return

    # The cooldown starts with the attempt, not with a success: a failed promote.yml
    # must never be retried in a loop (each run fences the primary again).
    last_failover = time.time()
    log.critical("*** TRIGGERING FAILOVER ***")
    alert("primary unhealthy, running promote.yml")
    log.info("Running ansible-playbook -i %s %s", INVENTORY, PLAYBOOK)

    try:
        result = subprocess.run(
            [
                "ansible-playbook",
                "-i", INVENTORY,
                PLAYBOOK,
            ],
            capture_output=True,
            text=True,
            timeout=300,
        )
        log.info("stdout:\n%s", result.stdout)
        if result.returncode != 0:
            log.error("stderr:\n%s", result.stderr)
            log.error("Playbook failed (exit %d). No retry for %ds.", result.returncode, COOLDOWN_SEC)
            alert(f"promote.yml FAILED (exit {result.returncode}). Not retrying for {COOLDOWN_SEC // 60} min: check both nodes by hand.")
        else:
            log.info("Failover completed successfully.")
            alert("failover completed: the standby is now primary")
    except subprocess.TimeoutExpired:
        log.error("Playbook timed out (300s).")
        alert("promote.yml timed out (300s). Not retrying until the cooldown ends.")
    except Exception as e:
        log.error("Ansible error: %s", e)
        alert(f"ansible error: {e}")


def main():
    global consecutive_failures

    log.info("Watchdog starting")
    log.info("  target:    %s", HEALTH_URL)
    log.info("  interval:  %ds", CHECK_INTERVAL)
    log.info("  threshold: %d failures", FAIL_THRESHOLD)
    log.info("  cooldown:  %ds (after any promote attempt)", COOLDOWN_SEC)
    log.info("  internet:  %s", ", ".join(INTERNET_CHECK_URLS))
    log.info("  alerts:    %s", "Discord" if DISCORD_WEBHOOK_URL else "off")

    while True:
        if check_health():
            if consecutive_failures > 0:
                log.info("Primary recovered after %d failure(s).", consecutive_failures)
            consecutive_failures = 0
        elif not internet_ok():
            # The watchdog itself is offline: it can't judge the primary. Don't count it.
            log.warning("Watchdog has no internet; skipping this round (failures stay at %d).", consecutive_failures)
        else:
            consecutive_failures += 1
            log.warning("FAIL %d/%d", consecutive_failures, FAIL_THRESHOLD)
            if consecutive_failures >= FAIL_THRESHOLD:
                trigger_failover()
                consecutive_failures = 0

        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()
