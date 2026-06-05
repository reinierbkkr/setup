# VPS setup

Single-file, idempotent provisioning script for a fresh Ubuntu 24.04 VPS
(DigitalOcean). Safe to rerun anytime. See `description.md` for the design spec
and `CLAUDE.md` for architecture conventions.

The script (`setup.sh`) automates almost everything. This README covers only the
**manual steps** — the things you must do by hand before, during, and after the
run, and the gotchas that bite on a fresh box.

---

## Two SSH keys, two different jobs

Don't confuse them:

| Key | Lives where | Purpose | Set via |
| --- | --- | --- | --- |
| **Your laptop's public key** | server `~/.ssh/authorized_keys` | you → server login | `SSH_PUBLIC_KEY` in `config.env` (and DO account, see below) |
| **Deploy key** (server keypair) | server `/opt/deploy/deploy_key` (private) + GitHub (public) | server → GitHub pull of private repos | `DEPLOY_KEY` in `config.env` |

---

## 1. Before the rebuild — add your laptop key to DigitalOcean

DigitalOcean injects SSH keys into a droplet **only at create/rebuild time**, via
cloud-init.

- DO panel → **Settings → Security → SSH Keys → Add SSH Key** → paste
  `~/.ssh/id_ed25519.pub` from your laptop.
- In the **Rebuild** dialog, select that key.

> ⚠️ Adding a key to your DO account *after* a rebuild does **not** push it to the
> running droplet. It just sits in the account until the next rebuild. If you
> forgot, see the console fallback below.

## 2. Rebuild → Ubuntu 24.04 LTS

DO panel → droplet → **Destroy → Rebuild** → pick **Ubuntu 24.04 LTS**. IP usually
stays the same.

## 3. Wait for SSH, then log in as root

Sshd is usually up **30–60 s** after the panel shows "complete" (up to ~2 min for
cloud-init). Poll instead of guessing:

```bash
until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@<IP> true 2>/dev/null; do
  echo "waiting..."; sleep 5
done; echo "up"
```

Same IP, new host key → if you get a host-key clash, clear it first:

```bash
ssh-keygen -R <IP>
```

### Fallback: forgot to add the key at rebuild

Use the **DO web console** (panel → Access → Launch Console), log in as root, then:

```bash
mkdir -p ~/.ssh
echo "<your-laptop-pubkey>" >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
```

`ssh root@<IP>` works immediately after — no second rebuild needed.

## 4. Copy the script and config to the server

```bash
ssh root@<IP> 'mkdir -p /opt/deploy'
scp setup.sh .env.example index.html root@<IP>:/opt/deploy/
```

## 5. Fill in `config.env`

```bash
ssh root@<IP>
cp /opt/deploy/.env.example /opt/deploy/config.env
nano /opt/deploy/config.env
```

- `ADMIN_USER` — required.
- `SSH_PUBLIC_KEY` — **required**. Paste your laptop's `~/.ssh/id_ed25519.pub`.
- Site/app vars — **optional**. Comment them out and those deploys are skipped
  cleanly (the script logs "Skipping" and moves on). Add them and rerun later.

> ⚠️ The script disables `PasswordAuthentication` and root password login. A wrong
> or missing `SSH_PUBLIC_KEY` will lock you out. **Keep the root SSH session open**
> until you've verified the new admin login works (step 8).

## 6. Deploy key for private repos (optional)

Skip if your repos are public.

**Reusing an existing key** (you saved the private key before the wipe):

```bash
scp deploy_key root@<IP>:/opt/deploy/deploy_key
ssh root@<IP> 'chmod 600 /opt/deploy/deploy_key'
```

**Generating a new one** (on the server):

```bash
ssh-keygen -t ed25519 -f /opt/deploy/deploy_key -N ""
cat /opt/deploy/deploy_key.pub
```

Add the public key to GitHub → repo **Settings → Deploy keys → Add** (read-only is
fine). Then set in `config.env`:

```bash
DEPLOY_KEY=/opt/deploy/deploy_key
```

Test before the full run:

```bash
GIT_SSH_COMMAND="ssh -i /opt/deploy/deploy_key -o IdentitiesOnly=yes" \
  git ls-remote git@github.com:you/repo.git
```

Refs listed = key works.

## 7. App runtime secrets (`/opt/deploy/<APP_NAME>.env`)

Separate from `config.env`. This holds the **docker app's** runtime env.

The script copies `/opt/deploy/<APP_NAME>.env` → `/opt/apps/<APP_NAME>/.env`
before `docker compose up`. **If this file is missing, the app launch is skipped**
(logged, non-fatal) so the rest of provisioning still completes — your compose file
typically references `.env` via `env_file:`, and launching without it would crash.

So: create it before you expect the app to run.

```bash
nano /opt/deploy/wintermute.env   # real values; filename = APP_NAME
```

Then rerun the script and the app launches.

## 8. Run the script

```bash
chmod +x /opt/deploy/setup.sh
/opt/deploy/setup.sh
```

Always run as **root**. The script does not switch users — it owns everything it
creates (`/opt/git`, `/var/www`, `/opt/apps`) as root, and docker/nginx don't need
otherwise. Running git commands against these repos as the `deploy` user yields a
`detected dubious ownership` error (uid mismatch) — that's expected, not corruption.
For manual git poking, use `sudo` or add a `safe.directory` entry.

## 9. Verify BEFORE closing the root session

In a **new** terminal:

```bash
ssh <ADMIN_USER>@<IP>
healthcheck
```

If the admin login works, you're safe to close root. If it's broken, fix it from the
still-open root session.

## 10. Post-setup manual steps (by design)

- **Tailscale** is installed but not auto-joined:
  ```bash
  sudo tailscale up
  ```
- **TLS / Let's Encrypt** only runs if `CERTBOT_EMAIL` is set in `config.env` **and**
  the domains already resolve to this box. Point DNS first (`dig +short <domain>`
  should return your IP), then rerun — it's idempotent.

---

## Notes on app deploy (docker)

- **Tags drive releases.** The script fetches tags and checks out the newest one. No
  tags on the repo → it deploys default-branch HEAD (logged, non-fatal). Push a tag
  and rerun to deploy a specific release.
- Rerunning fetches new tags (`git fetch --tags --force --prune`) and redeploys the
  latest — no manual cleanup needed.

## Troubleshooting quick reference

| Symptom | Cause / fix |
| --- | --- |
| `detected dubious ownership` | Running git as `deploy` on a root-owned repo. Use `sudo`, or `git config --global --add safe.directory /opt/git/<name>`. |
| `stat .../.env: no such file` from compose | Missing `/opt/deploy/<APP_NAME>.env`. Create it, rerun. |
| `git tag` empty | Repo has no tags → HEAD is deployed. Push a tag if you want a pinned release. |
| Host-key clash on SSH | `ssh-keygen -R <IP>` (same IP, new box). |
| Locked out after run | Wrong `SSH_PUBLIC_KEY`. Recover via DO web console. |
