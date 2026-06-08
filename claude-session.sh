#!/usr/bin/env bash
# Claude Code remote-control session setup
#
# Extracted from setup.sh for use on servers with enough RAM (≥2 GB recommended).
# Run as root after setup.sh has already provisioned the server.
#
# Required config (source config.env first, or export manually):
#   ADMIN_USER        — provisioned admin user (from config.env)
#
# Optional config:
#   CLAUDE_USER       — restricted no-sudo user to run Claude (default: $ADMIN_USER)
#   CLAUDE_WORKSPACE  — dir Claude works in (default: /home/$CLAUDE_USER/chula)
#   CLAUDE_REPOS      — space-separated git SSH URLs to clone/pull into workspace
#   DEPLOY_KEY        — path to GitHub deploy key on server (for private repos)
#
# Usage:
#   source /opt/deploy/config.env
#   bash /opt/deploy/claude-session.sh
#
# First-time auth (one-time only after running this script):
#   1. Stop the service to avoid two Claude processes crashing the server:
#        XDG_RUNTIME_DIR=/run/user/$(id -u claudebot) sudo -u claudebot systemctl --user stop claude-session
#   2. sudo su - claudebot
#   3. cd chula && claude   # /login, trust workspace, then exit
#   4. exit
#   5. bash /opt/deploy/claude-session.sh   # restarts session service
#   6. sudo runuser -u claudebot -- tmux attach -t claude

set -euo pipefail

CONFIG="${CONFIG:-/opt/deploy/config.env}"
[ -f "$CONFIG" ] && source "$CONFIG"

[ -n "${ADMIN_USER:-}" ] || { echo "[!] ADMIN_USER not set"; exit 1; }

log() { echo -e "\n[+] $1"; }

setup_claude_session() {
  log "Claude Code remote-control session"
  local user="${CLAUDE_USER:-$ADMIN_USER}"
  local uid
  uid=$(id -u "$user" 2>/dev/null || true)
  local svc_dir="/home/$user/.config/systemd/user"

  # Create restricted user if it differs from ADMIN_USER and doesn't exist yet.
  # No sudo — limits blast radius when running autonomously.
  if [ "$user" != "$ADMIN_USER" ]; then
    if id "$user" &>/dev/null; then
      echo "  [=] user $user (already exists)"
    else
      echo "  [-] creating restricted user $user"
      useradd -m -s /bin/bash "$user"
    fi
    uid=$(id -u "$user")
  fi

  if command -v claude &>/dev/null; then
    echo "  [=] claude (already installed)"
  else
    echo "  [-] installing @anthropic-ai/claude-code"
    npm install -g @anthropic-ai/claude-code
  fi

  local claude_bin
  claude_bin=$(command -v claude)

  loginctl enable-linger "$user"

  mkdir -p "$svc_dir"
  chown -R "$user:$user" "/home/$user/.config"

  if [ -n "${DEPLOY_KEY:-}" ] && [ -f "$DEPLOY_KEY" ]; then
    local ssh_dir="/home/$user/.ssh"
    local user_key="$ssh_dir/deploy_key"
    mkdir -p "$ssh_dir"
    cp "$DEPLOY_KEY" "$user_key"
    chmod 600 "$user_key"
    chown "$user:$user" "$user_key"
    cat >"$ssh_dir/config" <<EOF
Host github.com
  IdentityFile $user_key
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
    chmod 600 "$ssh_dir/config"
    chown -R "$user:$user" "$ssh_dir"
    echo "  [=] ~/.ssh/config wired to deploy key for github.com"
  fi

  local claude_settings="/home/$user/.claude/settings.json"
  mkdir -p "/home/$user/.claude"
  cat >"$claude_settings" <<'EOF'
{
  "permissions": {
    "allow": [
      "Bash(npm ci)",
      "Bash(npm run:*)",
      "Bash(npm test:*)",
      "Bash(sqlite3:*)",
      "Bash(git status)",
      "Bash(git diff:*)",
      "Bash(git log:*)",
      "Bash(git add:*)",
      "Bash(git commit:*)",
      "Bash(git branch:*)",
      "Bash(git checkout:*)",
      "Bash(git switch:*)",
      "Bash(git push:*)",
      "Read(**)",
      "Write(**)",
      "Edit(**)"
    ],
    "deny": [
      "Bash(rm -rf:*)",
      "Bash(git push --force:*)",
      "Bash(git push -f:*)",
      "Bash(git reset --hard:*)",
      "Bash(chmod:*)",
      "Bash(sudo:*)",
      "Bash(curl:*)",
      "Bash(wget:*)"
    ]
  }
}
EOF
  chown -R "$user:$user" "/home/$user/.claude"
  echo "  [=] claude settings: targeted allowlist (npm ci, sqlite3, git, read/write)"

  local workspace="${CLAUDE_WORKSPACE:-/home/$user/chula}"
  mkdir -p "$workspace"
  chown "$user:$user" "$workspace"

  if [ -n "${CLAUDE_REPOS:-}" ]; then
    local user_key="/home/$user/.ssh/deploy_key"
    local user_ssh_cmd="ssh -i $user_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    for repo in $CLAUDE_REPOS; do
      local name
      name=$(basename "$repo" .git)
      local dest="$workspace/$name"
      if [ ! -d "$dest/.git" ]; then
        echo "  [-] cloning $repo"
        runuser -u "$user" -- env GIT_SSH_COMMAND="$user_ssh_cmd" git clone "$repo" "$dest"
      else
        echo "  [=] pulling $dest"
        runuser -u "$user" -- env GIT_SSH_COMMAND="$user_ssh_cmd" git -C "$dest" pull --ff-only origin HEAD
      fi
    done
  fi

  cat >/usr/local/bin/claude-session-loop <<EOF
#!/bin/bash
cd $workspace
while true; do
  pkill -x claude 2>/dev/null || true
  sleep 3
  $claude_bin remote-control --remote-control-session-name-prefix "chula-\$(date +%H%M)"
  sleep 30
done
EOF
  chmod +x /usr/local/bin/claude-session-loop

  cat >"$svc_dir/claude-session.service" <<EOF
[Unit]
Description=Claude Code remote-control tmux session
After=network.target

[Service]
Type=forking
ExecStartPre=-/usr/bin/tmux kill-session -t claude
ExecStart=/usr/bin/tmux new-session -d -s claude /usr/local/bin/claude-session-loop
ExecStop=/usr/bin/tmux kill-session -t claude
RemainAfterExit=yes
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF

  chown "$user:$user" "$svc_dir/claude-session.service"

  systemctl start "user@${uid}.service" || true

  local runtime="/run/user/$uid"
  if [ -d "$runtime" ]; then
    XDG_RUNTIME_DIR="$runtime" runuser -u "$user" -- systemctl --user daemon-reload
    XDG_RUNTIME_DIR="$runtime" runuser -u "$user" -- systemctl --user enable claude-session
    XDG_RUNTIME_DIR="$runtime" runuser -u "$user" -- systemctl --user restart claude-session
    echo "  [+] claude-session service running — SSH in and: tmux attach -t claude"
  else
    mkdir -p "$svc_dir/default.target.wants"
    ln -sf "$svc_dir/claude-session.service" \
           "$svc_dir/default.target.wants/claude-session.service" 2>/dev/null || true
    echo "  [!] user manager not ready; service enabled, starts on next boot"
  fi

  echo ""
  echo "  [!] First-time setup (one-time only):"
  echo "        1. Stop service first (prevents two Claude processes crashing the server):"
  echo "             XDG_RUNTIME_DIR=/run/user/\$(id -u claudebot) sudo -u claudebot systemctl --user stop claude-session"
  echo "        2. sudo su - claudebot"
  echo "        3. cd chula && claude   # /login, trust workspace, then exit"
  echo "        4. exit"
  echo "        5. bash /opt/deploy/claude-session.sh   # restarts session"
  echo "        6. sudo runuser -u claudebot -- tmux attach -t claude"
  echo "        7. Ctrl+B D to detach"
  echo ""
}

setup_claude_session
