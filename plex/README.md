# Plex Media Server Setup

Idempotent provisioning script for a fresh Ubuntu 24.04 home media server. Safe to rerun anytime.

## What it does

- System update + security patches (unattended-upgrades, auto-reboot at 04:30)
- Admin user with passwordless sudo
- SSH hardening — disables password auth and root login if SSH keys are configured
- UFW firewall — SSH (rate-limited) + all Plex discovery ports
- fail2ban for SSH brute-force protection
- journald log size limits
- Weekly cleanup cron (autoremove, autoclean, vacuum logs)
- Node.js 22 (via nodesource)
- Tailscale (not auto-joined — run `tailscale up` manually after)
- Claude Code (`claude` available system-wide)
- Static IP via netplan (optional, applied last — SSH reconnect to new IP after script finishes)
- `healthcheck` command installed at `/usr/local/bin/healthcheck`

Plex itself is commented out (`install_plex`) — transfer existing Plex data manually first, then uncomment.

## Deploy

```bash
# Copy files to server
scp plex/setup.sh reinier@<server-ip>:~/
ssh reinier@<server-ip> "sudo tee /opt/setup/setup.sh" < plex/setup.sh
ssh reinier@<server-ip> "sudo tee /opt/setup/.env.example" < plex/.env.example

# Create and fill in config
ssh reinier@<server-ip> "sudo cp /opt/setup/.env.example /opt/setup/config.env && sudo nano /opt/setup/config.env"

# Run as root
ssh reinier@<server-ip> "sudo bash /opt/setup/setup.sh"
```

## Config (`/opt/setup/config.env`)

| Var | Required | Description |
|-----|----------|-------------|
| `ADMIN_USER` | Yes | Local user created with passwordless sudo |
| `SSH_KEY_1`, `SSH_KEY_2`, ... | No | Public keys added to authorized_keys; disables password auth when set |
| `STATIC_IP` | No | Static IP with CIDR, e.g. `192.168.1.5/24`; leave unset to keep DHCP |
| `GATEWAY` | If `STATIC_IP` set | Router IP, e.g. `192.168.1.1` |
| `DNS` | No | DNS server(s), defaults to `1.1.1.1, 8.8.8.8` |
| `PLEX_CLAIM` | No | Claim token from plex.tv/claim (expires in 4 min) to auto-link Plex account |
| `MEDIA_PATH` | No | Path to media directory, defaults to `/media/plex` |

## Post-setup

```bash
# Join Tailscale (browser auth often fails headless — use an auth key)
tailscale up --authkey=tskey-auth-xxxxx

# Check everything
healthcheck
```

## Lint before deploying

```bash
shellcheck plex/setup.sh
bash -n plex/setup.sh
```
