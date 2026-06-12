# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Two idempotent provisioning scripts for Ubuntu 24.04. No build system, no tests, no framework — just shell scripts plus config files. Safe to rerun anytime.

### VPS (`vps/`)

DigitalOcean VPS. Deployed to and run from `/opt/deploy/setup.sh` on the server.

- `vps/setup.sh` — all provisioning logic.
- `vps/.env.example` — template for the runtime config (copy to `/opt/deploy/config.env` on the server and fill in real values).
- `vps/description.md` — design spec / source of truth for intended behavior. The script does not yet implement everything described here (see Gaps below).
- `vps/placeholder/` — static placeholder page served by nginx before a real site is deployed.

### Media server (`plex/`)

Home media server (bare metal, LAN + Tailscale). Deployed to and run from `/opt/setup/setup.sh` on the server.

- `plex/setup.sh` — all provisioning logic.
- `plex/.env.example` — template for the runtime config (copy to `/opt/setup/config.env` on the server and fill in real values).
- `plex/README.md` — full deploy instructions and config reference.

## Running

The script is **not** run from this repo. It is deployed to the server and executed there as root:

```bash
# on the server
cp .env.example /opt/deploy/config.env   # then edit real values
sudo /opt/deploy/setup.sh
```

`config.env` is sourced for all variables (`ADMIN_USER`, `SSH_PUBLIC_KEY`, `SITE*_DOMAIN`, `SITE*_REPO`, `APP_NAME`, `APP_REPO`). Never commit a real `config.env`.

Lint locally before deploying:

```bash
shellcheck vps/setup.sh
bash -n vps/setup.sh   # syntax check only
```

## Architecture / conventions

- **Idempotent "ensure-style" functions.** Every action checks state before acting (`dpkg -s` before install, `id` before useradd, `command -v` before curl-installs, `.git` test before clone-vs-pull). New logic must follow this — assume the script runs repeatedly on an already-provisioned box.
- **`flock` single-instance guard** (`/var/lock/vps-setup.lock`) — concurrent runs exit silently. `set -euo pipefail` is on, so unhandled failures abort the whole run; deliberately-tolerant steps use `|| true`.
- **`main()` is the ordered pipeline.** Bootstrap pkgs → user → ssh → firewall → fail2ban → docker → journald → cleanup → nginx → tailscale → healthcheck → deploy sites → deploy app. Order matters (e.g. user/docker group before app deploy). Add new steps as a function and wire into `main()`.
- **Directory contract** (keep this separation): `/opt/git` = source repos, `/var/www/<domain>` = built static output, `/opt/apps/<name>` = running docker app, `/opt/deploy` = this script + config.
- **Deploy flow.** Static sites: clone/pull → `npm ci && npm run build` → `rsync --delete dist/ /var/www/<domain>` → write nginx vhost → reload. Docker app: clone/pull tags → checkout latest git tag → rsync to `/opt/apps` → `docker compose up -d --build`.
- **Generated files are heredoc'd** into place (sshd hardening, daemon.json, jail.local, journald limits, weekly cron, nginx vhosts, healthcheck). Edit the heredoc, not the server file — the server file is overwritten each run.

## Optional config vars

Beyond the core vars, `config.env` accepts:
- `DEPLOY_KEY` — path to a GitHub SSH deploy key on the server for private repos. Wired via `GIT_SSH_COMMAND` in `git_ssh()`.
- `CERTBOT_EMAIL` — set to enable Let's Encrypt TLS (`certbot --nginx --redirect`). Unset = HTTP-only. Domains must resolve to the box first or certbot is skipped non-fatally.
- `/opt/deploy/<APP_NAME>.env` — runtime secrets for the docker app, copied to `<app>/.env` before `docker compose up`. Not a `config.env` var; a separate file on the server.

## Known remaining caveats

- **Docker/UFW bypass is mitigated, not eliminated.** `setup_docker_firewall` writes a `DOCKER-USER` chain into `/etc/ufw/after.rules` that drops public-interface traffic to published container ports, allowing only loopback, the docker bridge (`172.16.0.0/12`), and Tailscale (`100.64.0.0/10`). This holds even if the compose file publishes on `0.0.0.0`. If an app legitimately needs public exposure, add an explicit `RETURN` rule for its port in that block.
- **Tailscale is not auto-joined** by design — run `tailscale up` manually post-setup.
- **Certbot auto-renew** relies on the distro's packaged systemd timer (installed with `certbot`); not separately configured here.
- **Static build assumes Vite-style `dist/`** output and an `npm` build. Other frameworks need the `rsync` source path adjusted in `deploy_static_site`.
