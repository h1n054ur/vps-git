# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [2.0.0] - 2026-09-27

Production hardening after running the stack across two regions: a private network switch, a real split-brain fence, offsite backups, alerting, and current dependencies throughout.

### Breaking changes and migration

- **Private network is Tailscale (was NetBird).** Inventory variables `primary_netbird_ip` / `standby_netbird_ip` are now `primary_tailnet_ip` / `standby_tailnet_ip`, the watchdog env vars `PRIMARY_NETBIRD_IP` / `STANDBY_NETBIRD_IP` are now `PRIMARY_TAILNET_IP` / `STANDBY_TAILNET_IP`, and the unused `netbird_ip` host variable is gone. Rename them in your `inventory.yml` and watchdog `.env`.
- **Serving containers no longer auto-start.** `forgejo`, `cloudflared` and `backup` are `restart: "no"` and are started by the split-brain fence (`vps-git-fence.timer`, installed by `deploy.yml`). If you run the stack by hand, install the fence units or start those services yourself after checking the peer.
- **Postgres binds to the node's own tailnet IP.** Set `pg_bind` / `PG_BIND` to each node's Tailscale IP instead of `0.0.0.0` (Docker port publishing bypasses ufw). The `common` role sets `net.ipv4.ip_nonlocal_bind=1` so the bind works at boot.
- **Uptime Kuma 2.** The watchdog uses `louislam/uptime-kuma:2`. An existing Kuma 1 data directory is migrated automatically on first start; back up the `kuma_data` volume first and let the migration finish (watch for "Aggregate Table Migration Completed" in the logs).
- **Forgejo 16** is the default image. Upgrading from 11 is a direct jump; follow [Upgrading Forgejo](README.md#upgrading-forgejo) (consistent backup with Forgejo stopped, failover agent and fence paused).

### Added

- **Split-brain fence** (`stack/fence.sh`, `vps-git-fence.timer`): every minute a node configured as primary compares its Postgres timeline with the peer and only serves while it is the newest primary. A returning old primary fences itself after a failover.
- **Deploy guards:** `deploy.yml` refuses to start a primary while the standby runs Forgejo, and refuses to re-initialise a standby that is serving as primary.
- **Failback support:** `promote.yml` stops the serving containers on the other node when it can reach it, and accepts `-e promote_target=<host>` to promote a demoted node back.
- **Offsite backups** (`stack/offsite-backup.sh`, `vps-git-offsite-backup.timer`): nightly encrypted restic snapshots of a Postgres dump plus the Forgejo data volume to Cloudflare R2 (or any S3 endpoint), 30 daily and 12 monthly kept, a weekly partial data check, primary-only.
- **Discord notifications** as Components V2 cards (`stack/notify.sh`): a live status card edited in place (serving node, Forgejo version and health, replication and lag, fence, last and next backup, disk, watchdog reachability, Actions runners), plus alert cards for backup failures, fence decision changes and watchdog loss or recovery.
- **Uptime Kuma card notifications:** `setup-kuma --discord-webhook` creates a default Webhook notification with a Liquid card template (`watchdog/setup-kuma/discord-card.liquid`), and `--extra-host NAME=HOST` adds ping and SSH monitors for more machines.
- **Forgejo mail and login:** Cloudflare SMTP mailer and GitHub OAuth login configured from environment variables.
- **Docs:** Networking (tailnet policy example, UDP 41641), split-brain fence and failback diagrams, Upgrading Forgejo, Offsite backups, Notifications, pinned versions and a full configuration reference.

### Changed

- **Dependencies:**
  - Forgejo 11 → 16
  - Uptime Kuma 1 → 2
  - cloudflared `latest` → pinned `2026.9.3`
  - Python base images 3.12 → 3.14
  - Alpine 3.21 → 3.24 (3.21 reaches end of life on 2026-11-01)
  - Postgres stays on 16 (supported until 2028-11), with the major upgrade path documented
- **Ansible:** fully qualified module names (`ansible.builtin.*`) and `true`/`false` booleans throughout. The watchdog role works on non-Debian hosts that already have Docker.
- **setup-kuma:** targets Kuma 2 (sends the monitor fields it requires) and exits non-zero if any monitor fails.
- **Backup sidecar:** connects to Postgres on `PG_BIND`, so a tailnet-only bind works.
- **Development:** the primary repository moved to Forgejo; GitHub is a push mirror that stays current.

### Fixed

- **Failback instructions:** they previously re-initialised the promoted node from the stale old primary, which discarded every write made during the failover.

## [1.0.0] - 2026-02-13

- Initial release: Forgejo with Postgres streaming replication, backup sidecar, Cloudflare Tunnel, Ansible deploy/promote/demote, and an Uptime Kuma watchdog with automatic failover.

[2.0.0]: https://github.com/h1n054ur/vps-git/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/h1n054ur/vps-git/releases/tag/v1.0.0
