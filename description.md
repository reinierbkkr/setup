🖥️ Base system
OS: Ubuntu 24.04 LTS (fresh VPS, DigitalOcean)
Purpose: personal projects + one production app
Architecture style: fully declarative + idempotent setup script
Entry point: /opt/deploy/setup.sh (can be rerun safely)
👤 Users & SSH
Single admin user: deploy
SSH key-based auth only
Root login: prohibit-password (no password login anywhere)
Password authentication: disabled
deploy user:
sudo access
added to docker group (passwordless docker usage)
🔥 Security
UFW enabled
allow: 22, 80, 443
allow: 41641/udp (Tailscale)
deny everything else
Fail2ban enabled (SSH protection)
SSH hardened (keys only)
No public exposure of Docker app
🐳 Docker
Docker + Docker Compose installed
One main app (Compose-based, single container)
App:
pulled from private GitHub repo (SSH deploy key)
built from latest git tag
uses .env file stored on server
runs only locally or via Tailscale
Docker logs:
max 10MB per file
max 3 files per container
Weekly cleanup:
prune images, containers, build cache (not volumes)
🌐 Nginx & websites
Static sites served via /var/www
Two domains:
example.com
example2.com
Flow:
repos cloned to /opt/git
built
output synced to /var/www/domain
Nginx reverse proxy + static hosting
Let’s Encrypt TLS via Certbot (auto-renew enabled)
🔐 Tailscale
Installed but NOT auto-joined
Manual tailscale up after setup
Docker app only accessible via Tailscale network
📁 Directory layout
/opt/git/        → source repositories
/opt/apps/       → deployed docker app
/opt/deploy/     → setup system + config + scripts
/var/www/        → nginx static sites
🧹 System maintenance / disk safety
journald limited (~500MB)
apt autoremove + autoclean weekly
docker prune weekly
log rotation enforced
25GB disk safety focused setup
⚙️ Deployment model
Fully idempotent “ensure-style” functions
Safe to rerun anytime
Configuration-driven (single config file / YAML-like structure)
Uses:
git pull / checkout latest tag
build frontend repos
rsync to /var/www
docker compose up --build for app
📊 Monitoring
Simple healthcheck script:
disk usage
RAM
docker status
nginx status
tailscale status
cert expiry
🧠 Key design principles
clean separation:
/opt/git = source
/var/www = deployed static output
/opt/apps = running services
no secrets in git
minimal but production-grade security
deterministic repeatable provisioning
no overengineering (no Ansible needed)

If you start a new chat, you can basically say:

“Continue from the VPS setup: Ubuntu 24.04, idempotent deploy script, nginx + docker compose + tailscale, two static sites in /var/www, one private docker app only via tailscale.”

and it will pick up cleanly from here.