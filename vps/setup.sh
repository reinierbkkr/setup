#!/usr/bin/env bash
set -euo pipefail

CONFIG="/opt/deploy/config.env"
LOCK="/var/lock/vps-setup.lock"

exec 9>"$LOCK"
flock -n 9 || { echo "[!] Another run in progress, exiting."; exit 0; }

if [ ! -f "$CONFIG" ]; then
  echo "[!] Missing config: $CONFIG (copy .env.example and fill it in)" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

export DEBIAN_FRONTEND=noninteractive

log() { echo -e "\n[+] $1"; }
die() { echo -e "\n[!] $1" >&2; exit 1; }

require_var() {
  local name="$1"
  [ -n "${!name:-}" ] || die "Required config var '$name' is empty in $CONFIG"
}

set_system_hostname() {
  [ -n "${NEW_HOSTNAME:-}" ] || { echo "  [=] hostname (NEW_HOSTNAME not set, skipping)"; return 0; }

  local current
  current=$(hostname)
  if [ "$current" = "$NEW_HOSTNAME" ]; then
    echo "  [=] hostname already $NEW_HOSTNAME"
    return 0
  fi

  log "Setting hostname: $current -> $NEW_HOSTNAME"
  hostnamectl set-hostname "$NEW_HOSTNAME"

  [ -f /etc/hosts ] && \
    sed -i -E "s/^(127\.0\.0\.1|127\.0\.1\.1).*/\1 $NEW_HOSTNAME/" /etc/hosts

  [ -f /etc/cloud/cloud.cfg ] && \
    sed -i 's/^preserve_hostname: [[:space:]]*false/preserve_hostname: true/' /etc/cloud/cloud.cfg
}

# Wire an optional GitHub deploy key for private-repo clones/pulls.
git_ssh() {
  if [ -n "${DEPLOY_KEY:-}" ] && [ -f "$DEPLOY_KEY" ]; then
    export GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  else
    export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
  fi
}

ensure_pkg() {
  if dpkg -s "$1" &>/dev/null; then
    echo "  [=] $1 (already installed)"
  else
    echo "  [-] installing $1"
    apt-get install -y "$1"
  fi
}

ensure_dir() {
  mkdir -p "$1"
}

ensure_user() {
  if id "$1" &>/dev/null; then
    echo "  [=] user $1 (already exists)"
  else
    echo "  [-] creating user $1"
    useradd -m -s /bin/bash "$1"
  fi
  usermod -aG sudo "$1"
  usermod -aG docker "$1" || true

  # Key-only login leaves no password, so plain sudo would be unusable.
  # Grant passwordless sudo for this single automation admin.
  cat >/etc/sudoers.d/90-"$1" <<EOF
$1 ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 440 /etc/sudoers.d/90-"$1"
  visudo -cf /etc/sudoers.d/90-"$1" >/dev/null || die "Bad sudoers for $1"
}

setup_ssh() {
  log "Configuring SSH"
  require_var SSH_PUBLIC_KEY

  mkdir -p /home/"$ADMIN_USER"/.ssh
  echo "$SSH_PUBLIC_KEY" > /home/"$ADMIN_USER"/.ssh/authorized_keys

  chmod 700 /home/"$ADMIN_USER"/.ssh
  chmod 600 /home/"$ADMIN_USER"/.ssh/authorized_keys
  chown -R "$ADMIN_USER":"$ADMIN_USER" /home/"$ADMIN_USER"/.ssh

  cat >/etc/ssh/sshd_config.d/hardening.conf <<EOF
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
EOF

  # Validate before restart — bad config must never lock us out.
  sshd -t || die "sshd config invalid, refusing to restart SSH"
  systemctl restart ssh
}

setup_firewall() {
  log "UFW setup"
  ensure_pkg ufw

  ufw default deny incoming
  ufw default allow outgoing

  ufw limit 22/tcp        # rate-limit SSH (fail2ban handles the rest)
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 41641/udp     # Tailscale

  # Tailnet-only app port: reachable on Tailscale interface, never public.
  if [ -n "${APP_PORT:-}" ]; then
    ufw allow in on tailscale0 to any port "$APP_PORT" proto tcp
  fi

  ufw --force enable
}

setup_fail2ban() {
  log "fail2ban setup"
  ensure_pkg fail2ban

  cat >/etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
}

setup_docker() {
  log "Docker setup"

  if command -v docker &>/dev/null; then
    echo "  [=] docker (already installed)"
  else
    echo "  [-] installing docker"
    curl -fsSL https://get.docker.com | sh
  fi

  usermod -aG docker "$ADMIN_USER"

  mkdir -p /etc/docker
  cat >/etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

  systemctl restart docker
}

setup_docker_firewall() {
  log "Restricting Docker published ports to Tailscale/local (UFW DOCKER-USER)"
  local rules=/etc/ufw/after.rules
  local marker="# BEGIN vps-setup docker-user"

  [ -f "$rules" ] || die "Missing $rules — is UFW installed?"
  if grep -qF "$marker" "$rules"; then
    echo "  [=] DOCKER-USER rules already applied"
    return 0
  fi

  # Docker publishes container ports straight into iptables, bypassing UFW.
  # The DOCKER-USER chain runs before Docker's own rules on forwarded traffic,
  # so filter it here: only loopback, the docker bridge subnets, and the
  # Tailscale network (CGNAT 100.64.0.0/10) may reach containers. Everything
  # arriving on the public interface is dropped. Host services (nginx on 80/443)
  # are unaffected — DOCKER-USER only sees traffic forwarded to containers.
  cat >>"$rules" <<'EOF'

# BEGIN vps-setup docker-user
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -i lo -j RETURN
-A DOCKER-USER -i docker0 -j RETURN
-A DOCKER-USER -i tailscale0 -j RETURN
-A DOCKER-USER -s 100.64.0.0/10 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -j DROP
COMMIT
# END vps-setup docker-user
EOF

  ufw reload || true
}

setup_journald() {
  log "journald limits"
  mkdir -p /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/limits.conf <<EOF
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
EOF

  systemctl restart systemd-journald
}

setup_unattended_upgrades() {
  log "unattended-upgrades (auto security patches + reboot)"
  ensure_pkg unattended-upgrades

  # Enable the periodic update/upgrade timers.
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  # Security-only origins. Feature/major bumps live in -updates and are
  # intentionally NOT allowed here — those are handled by deliberate manual
  # upgrades (see "Manual major updates" in README/description.md). Auto-reboot
  # fires only when a patch sets /var/run/reboot-required (kernel/libc).
  cat >/etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF

  systemctl enable --now unattended-upgrades &>/dev/null || true
}

setup_cleanup() {
  log "weekly cleanup cron"
  cat >/etc/cron.weekly/system-cleanup <<'EOF'
#!/bin/bash
apt-get autoremove -y
apt-get autoclean -y

docker image prune -af || true
docker container prune -f || true
docker builder prune -af || true
EOF

  chmod +x /etc/cron.weekly/system-cleanup
}

install_tailscale() {
  log "Tailscale"
  if command -v tailscale &>/dev/null; then
    echo "  [=] tailscale (already installed)"
  else
    echo "  [-] installing tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  # NOT auto-joined by design — run `tailscale up` manually after setup.
}

setup_nginx() {
  log "nginx setup"
  ensure_pkg nginx
  # Stock default vhost is a catch-all that can shadow our sites.
  rm -f /etc/nginx/sites-enabled/default
  systemctl enable nginx
}

deploy_static_site() {
  local DOMAIN="$1"
  local REPO="$2"
  local ALIASES="${3:-}"
  local IS_DEFAULT="${4:-}"

  [ -n "$DOMAIN" ] && [ -n "$REPO" ] || { log "Skipping static site (unset domain/repo)"; return 0; }

  log "Deploying static site $DOMAIN"
  git_ssh

  local BASE="/opt/git/$DOMAIN"
  local WWW="/var/www/$DOMAIN"

  ensure_dir "$BASE"
  ensure_dir "$WWW"

  if [ ! -d "$BASE/.git" ]; then
    echo "  [-] cloning $REPO"
    git clone "$REPO" "$BASE"
  else
    echo "  [-] pulling $BASE"
    git -C "$BASE" pull --ff-only
  fi

  cd "$BASE"
  # Build in a guarded block: a failed build must NOT wipe the live site.
  if npm ci && npm run build; then
    rsync -a --delete "$BASE/dist/" "$WWW/"
  else
    log "Build failed for $DOMAIN — keeping existing $WWW"
  fi

  local SERVER_NAMES="$DOMAIN www.$DOMAIN${ALIASES:+ $ALIASES}"
  local LISTEN_LINE="listen 80;"
  [ -n "$IS_DEFAULT" ] && LISTEN_LINE="listen 80 default_server;"

  cat >/etc/nginx/sites-available/"$DOMAIN" <<EOF
server {
  $LISTEN_LINE
  server_name $SERVER_NAMES;
  root $WWW;
  index index.html;

  location / {
    try_files \$uri \$uri/ /index.html;
  }
}
EOF

  ln -sf /etc/nginx/sites-available/"$DOMAIN" /etc/nginx/sites-enabled/

  nginx -t && systemctl reload nginx

  # TLS via Let's Encrypt (only if email set and DNS already points here).
  if [ -n "${CERTBOT_EMAIL:-}" ]; then
    ensure_pkg certbot
    ensure_pkg python3-certbot-nginx
    local CERTBOT_FLAGS="-d $DOMAIN -d www.$DOMAIN"
    if [ -n "$ALIASES" ]; then
      for _a in $ALIASES; do CERTBOT_FLAGS="$CERTBOT_FLAGS -d $_a"; done
    fi
    # shellcheck disable=SC2086
    certbot --nginx $CERTBOT_FLAGS --non-interactive --agree-tos \
      -m "$CERTBOT_EMAIL" --redirect --keep-until-expiring --expand \
      || log "Certbot failed for $DOMAIN (DNS not pointing here yet?) — left HTTP-only"
  fi
}

deploy_placeholder_site() {
  local DOMAIN="$1"
  local ALIASES="${2:-}"
  local IS_DEFAULT="${3:-}"
  local PLACEHOLDER="/opt/deploy/index.html"

  log "Deploying placeholder for $DOMAIN"

  local WWW="/var/www/$DOMAIN"
  ensure_dir "$WWW"

  if [ ! -f "$PLACEHOLDER" ]; then
    log "No placeholder at $PLACEHOLDER — skipping $DOMAIN"
    return 0
  fi

  sed "s/__DOMAIN__/$DOMAIN/g" "$PLACEHOLDER" > "$WWW/index.html"
  [ -f /opt/deploy/favicon.ico ] && cp /opt/deploy/favicon.ico "$WWW/favicon.ico"

  local SERVER_NAMES="$DOMAIN www.$DOMAIN${ALIASES:+ $ALIASES}"
  local LISTEN_LINE="listen 80;"
  [ -n "$IS_DEFAULT" ] && LISTEN_LINE="listen 80 default_server;"

  cat >/etc/nginx/sites-available/"$DOMAIN" <<EOF
server {
  $LISTEN_LINE
  server_name $SERVER_NAMES;
  root $WWW;
  index index.html;

  location / {
    try_files \$uri \$uri/ /index.html;
  }
}
EOF

  ln -sf /etc/nginx/sites-available/"$DOMAIN" /etc/nginx/sites-enabled/
  nginx -t && systemctl reload nginx

  if [ -n "${CERTBOT_EMAIL:-}" ]; then
    ensure_pkg certbot
    ensure_pkg python3-certbot-nginx
    local CERTBOT_FLAGS="-d $DOMAIN -d www.$DOMAIN"
    if [ -n "$ALIASES" ]; then
      for _a in $ALIASES; do CERTBOT_FLAGS="$CERTBOT_FLAGS -d $_a"; done
    fi
    # shellcheck disable=SC2086
    certbot --nginx $CERTBOT_FLAGS --non-interactive --agree-tos \
      -m "$CERTBOT_EMAIL" --redirect --keep-until-expiring --expand \
      || log "Certbot failed for $DOMAIN (DNS not pointing here yet?) — left HTTP-only"
  fi
}

deploy_docker_app() {
  NAME="$1"
  REPO="$2"

  [ -n "$NAME" ] && [ -n "$REPO" ] || { log "Skipping docker app (unset name/repo)"; return 0; }

  log "Deploying docker app $NAME"
  git_ssh

  BASE="/opt/git/$NAME"
  APP="/opt/apps/$NAME"

  ensure_dir "$BASE"
  ensure_dir "$APP"

  if [ ! -d "$BASE/.git" ]; then
    echo "  [-] cloning $REPO"
    git clone "$REPO" "$BASE"
  else
    echo "  [-] fetching tags for $NAME"
    git -C "$BASE" fetch --tags --force --prune
  fi

  cd "$BASE"
  LATEST_TAG="$(git tag --sort=-creatordate | head -n1 || true)"
  if [ -n "$LATEST_TAG" ]; then
    echo "  [-] checking out tag $LATEST_TAG"
    git checkout --force "$LATEST_TAG"
  else
    log "No tags on $NAME — deploying default branch HEAD"
  fi

  # Sync source into app dir, excluding VCS metadata.
  rsync -a --delete --exclude '.git' --exclude 'data/' "$BASE/" "$APP/"
  # Place the app's runtime secrets (kept out of git, on the server only).
  if [ -f "/opt/deploy/$NAME.env" ]; then
    cp "/opt/deploy/$NAME.env" "$APP/.env"
  else
    log "Missing /opt/deploy/$NAME.env — skipping launch of $NAME (provision the env, then rerun)"
    return 0
  fi

  # Ensure data dir exists and is owned by the user the container runs as (matches compose default 1000:1000).
  mkdir -p "$APP/data"
  chown 1000:1000 "$APP/data"

  cd "$APP"
  docker compose up -d --build
}


healthcheck() {
  cat >/usr/local/bin/healthcheck <<'EOF'
#!/bin/bash
echo "=== Services ==="
echo "Docker:    $(systemctl is-active docker)"
echo "Nginx:     $(systemctl is-active nginx)"
echo "Tailscale: $(systemctl is-active tailscaled)"
echo "Fail2ban:  $(systemctl is-active fail2ban)"

echo; echo "=== Tailscale ==="
tailscale status 2>/dev/null | head -n5 || echo "not up"

echo; echo "=== Docker containers ==="
docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || true

echo; echo "=== Disk / RAM ==="
df -h /
free -h

echo; echo "=== TLS certs ==="
for c in /etc/letsencrypt/live/*/cert.pem; do
  [ -e "$c" ] || continue
  echo "$(basename "$(dirname "$c")"): $(openssl x509 -enddate -noout -in "$c" | cut -d= -f2)"
done

EOF

  chmod +x /usr/local/bin/healthcheck
}

main() {
  log "Starting VPS setup"
  require_var ADMIN_USER

  apt-get update -y

  ensure_pkg git
  ensure_pkg curl
  ensure_pkg rsync
  ensure_pkg nodejs
  ensure_pkg npm
  ensure_pkg sqlite3
  ensure_pkg tmux

  ensure_user "$ADMIN_USER"

  set_system_hostname
  setup_ssh
  setup_firewall
  setup_fail2ban
  setup_docker
  setup_docker_firewall
  setup_journald
  setup_unattended_upgrades
  setup_cleanup
  setup_nginx
  install_tailscale
  healthcheck

  # Static sites — placeholder when domain is set but no repo configured
  # SITE1 is the default_server (catch-all fallback for unmatched hostnames).
  if [ -n "${SITE1_DOMAIN:-}" ]; then
    if [ -n "${SITE1_REPO:-}" ]; then
      deploy_static_site "$SITE1_DOMAIN" "$SITE1_REPO" "${SITE1_ALIASES:-}" "default"
    else
      deploy_placeholder_site "$SITE1_DOMAIN" "${SITE1_ALIASES:-}" "default"
    fi
  fi
  if [ -n "${SITE2_DOMAIN:-}" ]; then
    if [ -n "${SITE2_REPO:-}" ]; then
      deploy_static_site "$SITE2_DOMAIN" "$SITE2_REPO" "${SITE2_ALIASES:-}"
    else
      deploy_placeholder_site "$SITE2_DOMAIN" "${SITE2_ALIASES:-}"
    fi
  fi

  # Docker app
  deploy_docker_app "${APP_NAME:-}" "${APP_REPO:-}"

  log "DONE"
}

main "$@"
