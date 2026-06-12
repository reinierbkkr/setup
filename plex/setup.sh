#!/usr/bin/env bash
set -euo pipefail

CONFIG="/opt/setup/config.env"
LOCK="/var/lock/setup.lock"

exec 9>"$LOCK"
flock -n 9 || { echo "[!] Another run in progress, exiting."; exit 0; }

if [ ! -f "$CONFIG" ]; then
  echo "[!] Missing config: $CONFIG (copy .env.example and fill it in)" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

export DEBIAN_FRONTEND=noninteractive

log()  { echo -e "\n[+] $1"; }
die()  { echo -e "\n[!] $1" >&2; exit 1; }

require_var() {
  local name="$1"
  [ -n "${!name:-}" ] || die "Required config var '$name' is empty in $CONFIG"
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

  cat >/etc/sudoers.d/90-"$1" <<EOF
$1 ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 440 /etc/sudoers.d/90-"$1"
  visudo -cf /etc/sudoers.d/90-"$1" >/dev/null || die "Bad sudoers for $1"
}

update_system() {
  log "System update"
  apt-get update -y
  apt-get upgrade -y
  apt-get dist-upgrade -y
}

setup_ssh() {
  log "SSH"
  require_var ADMIN_USER
  local auth_keys="/home/$ADMIN_USER/.ssh/authorized_keys"

  # Collect all SSH_KEY_* vars from config
  local keys=()
  while IFS= read -r var; do
    keys+=("${!var}")
  done < <(compgen -v | grep '^SSH_KEY_' | sort)

  if [ ${#keys[@]} -eq 0 ]; then
    echo "  [=] no SSH_KEY_* vars set, leaving password auth unchanged"
    return 0
  fi

  ensure_dir "/home/$ADMIN_USER/.ssh"
  chmod 700 "/home/$ADMIN_USER/.ssh"

  for key in "${keys[@]}"; do
    if grep -qF "$key" "$auth_keys" 2>/dev/null; then
      echo "  [=] key already present: ${key##* }"
    else
      echo "$key" >> "$auth_keys"
      echo "  [-] key added: ${key##* }"
    fi
  done

  chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  chmod 600 "$auth_keys"

  cat >/etc/ssh/sshd_config.d/90-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
AuthenticationMethods publickey
EOF

  systemctl reload ssh
  echo "  [-] password auth disabled"
}

setup_static_ip() {
  log "Static IP"
  [ -n "${STATIC_IP:-}" ] || { echo "  [=] STATIC_IP not set, skipping"; return 0; }
  [ -n "${GATEWAY:-}" ]   || die "GATEWAY required when STATIC_IP is set"

  local iface
  iface=$(ip route show default | awk '/default/ {print $5; exit}')
  [ -n "$iface" ] || die "Cannot detect default network interface"

  local netplan_file="/etc/netplan/01-netcfg.yaml"

  if grep -q "dhcp4: false" "$netplan_file" 2>/dev/null && grep -q "${STATIC_IP%%/*}" "$netplan_file" 2>/dev/null; then
    echo "  [=] static IP already configured ($STATIC_IP on $iface)"
    return 0
  fi

  local dns="${DNS:-1.1.1.1, 8.8.8.8}"

  cat >"$netplan_file" <<EOF
network:
  version: 2
  ethernets:
    $iface:
      dhcp4: false
      addresses: [$STATIC_IP]
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [$dns]
EOF

  # Defer apply by 5s so SSH session can exit cleanly before IP changes.
  # Reconnect to the new IP ($STATIC_IP) after this script finishes.
  systemd-run --on-active=5 netplan apply
  echo "  [!] IP changing to ${STATIC_IP%%/*} in ~5s — reconnect to new IP after script finishes"
}

setup_firewall() {
  log "UFW setup"
  ensure_pkg ufw

  ufw default deny incoming
  ufw default allow outgoing

  ufw limit 22/tcp                  # SSH, rate-limited

  # Plex
  ufw allow 32400/tcp               # Plex Web/API
  ufw allow 1900/udp                # DLNA/uPnP discovery
  ufw allow 5353/udp                # mDNS
  ufw allow 32410/udp               # Plex GDM (local discovery)
  ufw allow 32412/udp
  ufw allow 32413/udp
  ufw allow 32414/udp
  ufw allow 32469/tcp               # DLNA server

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

setup_journald() {
  log "journald limits"
  ensure_dir /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/limits.conf <<EOF
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
EOF

  systemctl restart systemd-journald
}

setup_unattended_upgrades() {
  log "unattended-upgrades (security patches)"
  ensure_pkg unattended-upgrades

  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

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
journalctl --vacuum-time=90d
EOF

  chmod +x /etc/cron.weekly/system-cleanup
}

install_nodejs() {
  log "Node.js"
  if command -v node &>/dev/null; then
    echo "  [=] node $(node --version) (already installed)"
    return 0
  fi

  echo "  [-] installing Node.js 22 via nodesource"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
}

install_plex() {
  log "Plex Media Server"

  if dpkg -s plexmediaserver &>/dev/null; then
    echo "  [=] plexmediaserver (already installed)"
    # Still ensure media dirs exist and ownership is correct
  else
    echo "  [-] adding Plex repo"
    curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key \
      | gpg --dearmor \
      | tee /usr/share/keyrings/plex-archive-keyring.gpg >/dev/null

    echo "deb [signed-by=/usr/share/keyrings/plex-archive-keyring.gpg] https://downloads.plex.tv/repo/deb public main" \
      | tee /etc/apt/sources.list.d/plexmediaserver.list

    apt-get update -y
    apt-get install -y plexmediaserver
  fi

  # Set claim token before first start if provided (auto-links server to Plex account).
  # Get a token at https://www.plex.tv/claim — expires in 4 minutes.
  if [ -n "${PLEX_CLAIM:-}" ]; then
    local env_file=/etc/default/plexmediaserver
    if grep -q "PLEX_CLAIM=" "$env_file" 2>/dev/null; then
      sed -i "s|^PLEX_CLAIM=.*|PLEX_CLAIM=${PLEX_CLAIM}|" "$env_file"
    else
      echo "PLEX_CLAIM=${PLEX_CLAIM}" >> "$env_file"
    fi
  fi

  # Create media dirs and grant plex access.
  ensure_dir "${MEDIA_PATH:-/media/plex}"
  chown -R plex:plex "${MEDIA_PATH:-/media/plex}" || true

  systemctl enable plexmediaserver
  systemctl restart plexmediaserver
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

install_claude_code() {
  log "Claude Code"
  require_var ADMIN_USER

  if command -v claude &>/dev/null; then
    echo "  [=] claude (already installed)"
    return 0
  fi

  echo "  [-] installing @anthropic-ai/claude-code"
  npm install -g @anthropic-ai/claude-code
}

healthcheck() {
  cat >/usr/local/bin/healthcheck <<'EOF'
#!/bin/bash
echo "=== Services ==="
echo "Plex:      $(systemctl is-active plexmediaserver)"
echo "Tailscale: $(systemctl is-active tailscaled)"
echo "Fail2ban:  $(systemctl is-active fail2ban)"
echo "UFW:       $(ufw status | head -1)"

echo; echo "=== Tailscale ==="
tailscale status 2>/dev/null | head -n5 || echo "not up"

echo; echo "=== Plex port ==="
ss -tlnp | grep 32400 || echo "32400 not listening"

echo; echo "=== Disk / RAM ==="
df -h /
free -h

echo; echo "=== Media dirs ==="
df -h "${MEDIA_PATH:-/media/plex}" 2>/dev/null || echo "no media dir"
EOF

  chmod +x /usr/local/bin/healthcheck
}

main() {
  log "Starting Plex media server setup"
  require_var ADMIN_USER

  update_system

  ensure_pkg git
  ensure_pkg curl
  # ensure_pkg gnupg  # needed for Plex repo GPG key — uncomment when install_plex is re-enabled
  ensure_pkg tmux
  ensure_pkg sqlite3

  ensure_user "$ADMIN_USER"
  setup_ssh
  setup_firewall
  setup_fail2ban
  setup_journald
  setup_unattended_upgrades
  setup_cleanup
  install_nodejs
  install_tailscale
  # install_plex  # TODO: transfer existing Plex setup manually first
  install_claude_code
  healthcheck
  setup_static_ip

  log "DONE"
  echo ""
  # echo "  Plex:        http://localhost:32400/web"
  echo "  Claude Code: run 'claude' as $ADMIN_USER"
  echo "  Healthcheck: run 'healthcheck'"
}

main "$@"
