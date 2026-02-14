# vps-git

Self-hosted [Forgejo](https://forgejo.org/) instance with high availability, streaming replication, automatic failover, and zero-downtime recovery -- deployed and managed entirely through Ansible.

## Architecture

```
                       +-----------------------+
                       |    Cloudflare Tunnel  |
                       |   git.example.com     |
                       +----------+------------+
                                  |
                  Tunnel connector (active node)
                                  |
            +---------------------+---------------------+
            |                                           |
   +--------v----------+                    +-----------v---------+
   |  Primary (Berlin)  |   WAL streaming   |  Standby (Kansas)   |
   |                    | ================> |                     |
   |  postgres          |   forgejo rsync   |  postgres           |
   |  forgejo           | ----------------> |  (hot standby)      |
   |  cloudflared       |                   |                     |
   |  backup sidecar    |                   |  cloudflared creds  |
   +--------------------+                   |  (ready to start)   |
            ^                               +---------------------+
            |                                           ^
            |          +-------------------+            |
            +----------+  Watchdog (local) +------------+
                       |                   |
                       |  uptime-kuma      |
                       |  failover agent   |
                       |  cloudflared      |
                       +-------------------+
                       status-git.example.com
```

**Primary** runs the full stack (Postgres, Forgejo, cloudflared, backup sidecar). **Standby** runs Postgres as a hot standby streaming replica and receives periodic Forgejo data rsyncs. If the primary goes down, the **watchdog** automatically promotes the standby via Ansible -- Cloudflare routes traffic to the new primary within seconds.

## Components

| Directory | Contents |
|---|---|
| `stack/` | Docker Compose stack with profile-based deployment (`primary` / `standby`) |
| `ansible/` | Playbooks: `deploy.yml`, `promote.yml` (failover), `demote.yml` (failback), `watchdog.yml` |
| `watchdog/` | Uptime Kuma monitoring + auto-failover agent + cloudflared tunnel + auto-setup |
| `cloudflared/` | Tunnel configuration templates |

## Prerequisites

- Two VPS nodes (Debian 12 / Ubuntu 24.04) with Docker installed
- Private network connectivity between nodes ([NetBird](https://netbird.io/), WireGuard, Tailscale, etc.)
- Cloudflare account with a domain
- Ansible on your control machine (`pip install ansible` or `brew install ansible`)
- A machine to run the watchdog (your laptop, a 3rd VPS, etc.)

## Setup

### 1. Clone and configure

```sh
git clone https://github.com/youruser/vps-git.git
cd vps-git
cp ansible/inventory.example.yml ansible/inventory.yml
```

Edit `ansible/inventory.yml` with your:
- VPS IPs and SSH key paths
- Postgres and replication passwords (generate strong random ones)
- Forgejo admin credentials (`forgejo_admin_user`, `forgejo_admin_password`, `forgejo_admin_email`)
- NetBird/WireGuard peer IPs
- Cloudflare tunnel credentials path

### 2. Create a Cloudflare Tunnel

```sh
cloudflared tunnel create vps-git
cloudflared tunnel route dns vps-git git.yourdomain.com
```

Copy the tunnel credentials JSON to `ansible/inventory.yml` under `tunnel_credentials_file`.

### 3. Deploy

```sh
cd ansible

# Deploy primary (creates admin user automatically on first run)
ansible-playbook deploy.yml -l primary

# Deploy standby (initializes Postgres streaming replica)
ansible-playbook deploy.yml -l standby -e init_standby_pg=true
```

Forgejo will be live at your configured URL with the admin user pre-created. No manual web setup required.

### 4. Deploy the watchdog

The watchdog runs on your local machine or a 3rd VPS. It monitors the primary and auto-promotes the standby on sustained failure.

**Option A: Via Ansible (recommended)**

Add the `watchdog` group to your `ansible/inventory.yml` (see the example inventory for all variables), then:

```sh
cd ansible
ansible-playbook watchdog.yml
```

This deploys the full watchdog stack, creates an Uptime Kuma admin account, and auto-configures all monitors (Forgejo health, web, Postgres and SSH on both nodes). The dashboard is login-protected to avoid leaking infrastructure details.

**Option B: Manual**

```sh
cd watchdog
cp env.example .env
# Edit .env with your health URL, SSH keys, Kuma credentials, NetBird IPs
docker compose --env-file .env up -d

# First time only: create Kuma admin + monitors
docker compose --env-file .env run --rm setup-kuma \
  --url http://localhost:3001 \
  --username admin \
  --password 'YourPassword' \
  --health-url https://git.yourdomain.com/api/healthz \
  --primary-host 100.x.x.x \
  --standby-host 100.y.y.y
```

The stack includes:
- **Uptime Kuma** -- monitoring dashboard (login-protected, no public status page)
- **Failover agent** -- health-checks the primary, auto-runs `promote.yml` after consecutive failures
- **cloudflared** -- tunnels the dashboard to your status domain
- **setup-kuma** -- one-shot container that creates the admin account and all monitors

### 5. Verify

```sh
# Health check
curl https://git.yourdomain.com/api/healthz

# API
curl -u admin:password https://git.yourdomain.com/api/v1/user

# Replication status (from primary)
ssh root@primary "docker exec vps-git-postgres psql -U forgejo -d forgejo \
  -c 'SELECT client_addr, state FROM pg_stat_replication;'"
```

## Failover

### Automatic

The watchdog checks the primary's health endpoint every 30 seconds. After 3 consecutive failures (configurable), it runs `promote.yml` which:

1. Stops standby containers
2. Promotes Postgres out of recovery (removes `standby.signal`)
3. Restores latest Forgejo data from backup sync
4. Starts the full primary stack (Postgres, Forgejo, cloudflared, backup)
5. Cloudflare tunnel routes traffic to the new primary automatically

A 1-hour cooldown prevents repeated failovers.

### Manual

```sh
cd ansible
ansible-playbook promote.yml
```

### Failback

Once the old primary is back online:

```sh
ansible-playbook demote.yml -l standby -e init_standby_pg=true
```

This wipes the promoted node's Postgres data, re-syncs from the current primary via `pg_basebackup`, and starts it as a streaming replica.

## Replication

| Layer | Method | RPO |
|---|---|---|
| Database | Postgres streaming replication (async) | Near-zero (WAL stream) |
| Forgejo data | rsync via backup sidecar | Up to `backup_interval` (configurable, default 60s) |
| Postgres dumps | `pg_dump` via backup sidecar | Up to `backup_interval` |

The backup sidecar runs on the primary and transfers data to the standby over the private network (NetBird/WireGuard) via SSH.

## For developers: migrating from GitHub

If you have an existing clone of a repo that's been mirrored to this Forgejo instance:

```sh
# Add Forgejo as a new remote
git remote add forgejo https://git.example.com/youruser/REPO_NAME.git

# Or replace origin entirely
git remote set-url origin https://git.example.com/youruser/REPO_NAME.git

# Push/pull as usual
git push origin main
git pull origin main
```

To clone fresh:

```sh
git clone https://git.example.com/youruser/REPO_NAME.git
```

HTTPS authentication uses your Forgejo username and password (or a personal access token created at `https://git.example.com/user/settings/applications`).

## Configuration reference

All configuration lives in `ansible/inventory.yml` (gitignored). Key variables:

| Variable | Description |
|---|---|
| `postgres_password` | Postgres password for the Forgejo database |
| `repl_password` | Postgres streaming replication password |
| `forgejo_admin_user` | Admin username (created on first deploy) |
| `forgejo_admin_password` | Admin password |
| `forgejo_admin_email` | Admin email |
| `app_url` | Public URL (e.g. `https://git.yourdomain.com`) |
| `tunnel_credentials_file` | Path to Cloudflare tunnel credentials JSON |
| `peer_host` | Private network IP of the peer node |
| `pg_bind` | Postgres bind address (`0.0.0.0` on both nodes for monitoring) |
| `backup_interval` | Seconds between backup/sync runs (default: 60) |
| `backup_ssh_key` | SSH private key for rsync between nodes |
| `watchdog_tunnel_uuid` | Cloudflare tunnel UUID for status page |
| `watchdog_status_hostname` | Hostname for Uptime Kuma (e.g. `status-git.yourdomain.com`) |
| `kuma_username` / `kuma_password` | Uptime Kuma admin credentials |
| `primary_netbird_ip` / `standby_netbird_ip` | Private network IPs for port monitors |
| `watchdog_check_interval` | Seconds between health checks (default: 30) |
| `watchdog_fail_threshold` | Consecutive failures before failover (default: 3) |

## Repository layout

```
vps-git/
  stack/
    compose.yml               Docker Compose (profiles: primary, standby)
    env.example                Environment variable template
    postgres/
      init-replication.sh      Creates replication user on Postgres init
    backup/
      Dockerfile               Backup sidecar (pg_dump + rsync)
      entrypoint.sh
  ansible/
    ansible.cfg
    inventory.example.yml      Inventory template
    deploy.yml                 Deploy stack to nodes
    promote.yml                Failover: promote standby
    demote.yml                 Failback: demote to standby
    watchdog.yml               Deploy watchdog stack
    roles/
      common/                  Base packages + Docker
      vps-git/                 Stack deployment + config templating
      watchdog/                Watchdog deployment + Kuma auto-setup
  watchdog/
    compose.yml                Uptime Kuma + failover + cloudflared + setup-kuma
    env.example
    failover/
      Dockerfile
      failover.py              Health check loop + Ansible trigger
      entrypoint.sh            SSH config setup
    setup-kuma/
      Dockerfile
      setup-kuma.py            Socket.IO script: creates admin + monitors
  cloudflared/
    config.yml.example         Tunnel ingress template
```

## License

[MIT](LICENSE)
