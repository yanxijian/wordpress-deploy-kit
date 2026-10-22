# wordpress-deploy-kit

**English** · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

[![hygiene](https://github.com/yanxijian/wordpress-deploy-kit/actions/workflows/hygiene.yml/badge.svg)](https://github.com/yanxijian/wordpress-deploy-kit/actions/workflows/hygiene.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu-E95420.svg)](https://ubuntu.com/)

A single-file script that **deploys a production WordPress site on an Ubuntu
cloud server in one command**. That command installs, configures, verifies and
sets up auto-renewal for Nginx + MariaDB + PHP-FPM + WordPress (Chinese
edition) + Let's Encrypt HTTPS; the whole run takes about 5–8 minutes.

## Features

- **Fully automatic**: nine deployment stages run in order; `set -e` plus an
  ERR trap stop at the first failure and report the line number, so nothing
  keeps running in a broken state
- **Interactive input up front**: only five prompts at the start (domain, two
  database passwords, notification email, confirmation); everything afterwards
  is unattended and supports piped answers
- **Optional password generation**: leave a password prompt empty and an
  8-character random password (digits + upper/lower case) is generated from
  `/dev/urandom`
- **Public IP auto-detection**: ifconfig.me → ipify → local NIC as a
  three-level fallback, no manual input
- **Multi-source WordPress download**: local archive first → official downloads
  endpoint → mirrors, all with timeouts; **the archive is validated with
  `tar -tzf` after download** (mirrors that change layout or rate-limit return
  HTML error pages while wget still exits 0), and the next source is tried
  automatically; when every source fails the script prints clear manual
  recovery steps
- **HTTPS fully managed**: certbot issues the certificate and rewrites Nginx
  for SSL with a forced 301 from 80 to 443; a systemd timer renews
  automatically and a deploy hook reloads Nginx; if the certificate step fails
  the script only warns and the HTTP site keeps working
- **Self-healing**: rebuilds a corrupt MariaDB data directory, auto-detects the
  PHP-FPM socket, and generates equivalent Salts locally when the official API
  is unreachable
- **Upload limits raised**: nginx `client_max_body_size 512m` plus PHP
  `upload_max_filesize/post_max_size 512M`, so backup plugins and large media
  no longer hit 413
- **Media library works**: installs `php-gd` / `php-imagick` plus
  mbstring/xml/curl/zip/intl by default; Nginx `try_files` falls back to
  `index.php`, so permalinks and `/wp-json` REST uploads work
- **Automatic small-memory tuning**: writes a mu-plugin that picks the image
  engine from `/proc/meminfo` (<2G prefers GD, ≥2G prefers Imagick) and skips
  the 1536/2048 thumbnails on low memory; big-image scaling is disabled so the
  site serves full-resolution originals
- **Low-memory tuning** (only when physical RAM < 1G; larger machines are left
  untouched): creates and enables a 1G swapfile when no swap exists; narrows
  the PHP-FPM `memory_limit` to 128M when it is `-1` or above 128M (so a single
  request cannot eat all RAM); switches the FPM pool to `ondemand` and computes
  `max_children` from RAM; skip it with `WPDK_SKIP_LOWMEM_TUNE=1`
- **Rerun-safe**: repeating the run on an already deployed machine does not
  stop because a password or database already exists; an existing
  `wp-config.php` is backed up and restored verbatim
- **Hardened out of the box** (all steps idempotent and rerunnable):
  - backfills the real password into `/etc/mysql/debian.cnf` → fixes the
    **daily midnight `logrotate.service` failure** (the default is "root +
    empty password", and §3 switches root to password auth, so it would
    inevitably log `Access denied`)
  - forbids PHP execution under `uploads/` (the upload directory serves static
    files only, closing the most common getshell path; images and other static
    files still work)
  - writes `DISALLOW_FILE_EDIT` into `wp-config.php`: plugin/theme code cannot
    be edited from the dashboard
  - mu-plugin blocks **XML-RPC** (`system.multicall` password amplification,
    pingback abuse) and **user enumeration** (REST `/wp/v2/users`, `?author=N`)
  - Nginx `server_tokens off`; blocks direct access to `readme.html` and
    `wp-config.php`
  - enables unattended security updates; on Ubuntu 20.04 it suggests enabling
    the free Ubuntu Pro/ESM
  - **when `/root/.ssh/authorized_keys` contains a public key**, switches to
    "key-only login + brute-force resistance" (`MaxAuthTries 3` /
    `MaxStartups`); an interactive run arms a 15-minute auto-rollback net
- **Small-memory PHP-FPM tuning**: sets `pm=ondemand` / `max_children` /
  `max_requests` from physical RAM, reducing 503s when concurrency or wp-cron
  saturates the pool
- **Credentials on disk**: key credentials are written to
  `/root/wp-credentials-<domain>.txt` (mode 600, root-only), with a reminder
  not to keep deployment logs that contain plaintext passwords
- **Final summary prints every key credential**: database password, certificate
  paths and management-script usage in one place, plus a post-deployment
  health check

## Requirements

| Item | Requirement |
| --- | --- |
| OS | **Ubuntu 20.04 (recommended)**, 22.04 / 24.04 also work (Debian family) |
| Privileges | root |
| Network | inbound 80 / 443 open (open them in the cloud security group) |
| HTTPS (optional) | a domain already resolving to this server; without a domain the script skips the certificate step |
| Local | ssh / scp (to upload the script) |

> **OS version advice**: on small VPS instances (1 vCPU, 1G/2G RAM) prefer the
> Ubuntu 20.04 image. Newer releases ship heavier components and use more
> memory, and installation or normal operation can stutter or even hang on a
> 1–2G machine; 2G+ machines may pick any supported release. On a small-memory
> machine, add swap before deploying (for example
> `fallocate -l 1G /swapfile`).

## Quick start

### Deployment steps

```bash
# 1. Upload
scp wp_deploy.sh root@<server-ip>:/root/

# 2. Run
ssh root@<server-ip>
bash /root/wp_deploy.sh

# 3. When it finishes, open http://<domain-or-ip>/ and complete the WordPress setup wizard
```

Five prompts at the start (all accept the default by pressing Enter):

| # | Prompt | Default on Enter |
| --- | --- | --- |
| 1 | Domain | use the public IP as `server_name` (HTTPS is skipped) |
| 2 | MariaDB root password | generated automatically |
| 3 | WordPress database password | generated automatically |
| 4 | Let's Encrypt notification email | left empty (renewal still works, you just get no expiry mail) |
| 5 | Confirmation | start deploying |

### Unattended (piped answers)

```bash
printf 'example.com\n<root password>\n<db password>\nyou@example.com\ny\n' | bash /root/wp_deploy.sh
```

An empty line for a password generates it automatically; for example, generate
both passwords:

```bash
printf 'example.com\n\n\nyou@example.com\ny\n' | bash /root/wp_deploy.sh
```

### Optional environment variables (defaults are the recommended values)

| Variable | Effect | When you need it |
| --- | --- | --- |
| `WPDK_ALLOW_XMLRPC=1` | keep the XML-RPC endpoint (blocked by default) | using the **WordPress mobile app** or Jetpack |
| `WPDK_SKIP_SSH_HARDEN=1` | skip "key-only login" hardening (on by default when a public key exists) | you want to verify the key first, or the machine has other login methods |
| `WPDK_SKIP_LOWMEM_TUNE=1` | skip the low-memory tuning (no swapfile, no `memory_limit` change) | RAM < 1G but you have your own memory/swap plan |

```bash
# Example: the site needs the WP mobile app and SSH must stay untouched
WPDK_ALLOW_XMLRPC=1 WPDK_SKIP_SSH_HARDEN=1 bash /root/wp_deploy.sh
```
> If the server cannot download the WordPress archive, download
> [latest-zh_CN.tar.gz](https://cn.wordpress.org/latest-zh_CN.tar.gz) locally,
> run `scp latest-zh_CN.tar.gz root@<server-ip>:/root/wp_latest_zh.tar.gz`, and
> run the script again — it will use the uploaded archive automatically.

## Deployment stages

| Stage | What happens |
| --- | --- |
| §2 | install Nginx and enable it at boot |
| §3 | install MariaDB; run non-interactive hardening (set the root password, drop anonymous users and the test database); wait for the socket; **backfill `/etc/mysql/debian.cnf`** (fixes the daily logrotate failure) |
| §4 | create the `wordpress` database (utf8mb4) and a dedicated user limited to localhost |
| §5 | install PHP-FPM and the usual WordPress extensions (mysql/gd/imagick/mbstring/xml/curl/zip/intl), detect the real socket path; **tune the FPM pool from RAM** (ondemand / max_children / max_requests); **extra low-memory (<1G) tuning**: create a 1G swapfile when needed and narrow `memory_limit` to 128M |
| §6 | rewrite the Nginx site config (PHP FastCGI, `try_files` → `index.php`, server_name) after backing it up, then apply it once `nginx -t` passes; **includes uploads PHP blocking, `server_tokens off` and sensitive-file blocks** |
| §7 | write a temporary `info.php` probe, verify the Nginx ↔ PHP-FPM path with a local curl, then delete it immediately |
| §8 | download the Chinese WordPress release from multiple sources with validation; generate `wp-config.php` (database settings and random Salts) |
| §9 | deploy to `/var/www/html`, write the mu-plugin that picks GD/Imagick from RAM, set the owner to `www-data`, verify the home page with a local curl; **also writes the enumeration block / XML-RPC block mu-plugin and `DISALLOW_FILE_EDIT`** |
| §10 | install certbot and issue the Let's Encrypt certificate, force 80 → 443, configure auto-renewal (skipped when there is no domain) |
| §11 | security baseline and health check: unattended updates, logrotate recheck, key-only SSH (when a key exists), credentials on disk, post-deploy check |

### HTTPS auto-renewal

Let's Encrypt certificates are valid for 90 days. After §10 the server has a
complete unattended renewal chain:

1. **certbot.timer** (systemd): checks twice a day and renews 30 days before
   expiry; if the timer is missing the script writes a `/etc/cron.d` fallback
2. **deploy hook**: `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`
   reloads Nginx with the new certificate after a successful renewal
3. **renewal rehearsal**: at the end of the deployment,
   `certbot renew --dry-run` exercises the whole chain against the staging
   environment

### Manual certificate management

The script generates `/root/cert_manage.sh` on the server:

```bash
bash /root/cert_manage.sh status    # certificate (domain / expiry / paths)
bash /root/cert_manage.sh renew     # renew manually (only when close to expiry)
bash /root/cert_manage.sh force     # force reissue now (mind the Let's Encrypt rate limits)
bash /root/cert_manage.sh dryrun    # renewal rehearsal
bash /root/cert_manage.sh reissue   # reissue and install (after a failed certificate step)
```

## Fault tolerance and self-healing

| Situation | Script behaviour |
| --- | --- |
| any stage fails | `set -e` + ERR trap stop immediately and print the failing line and context |
| MariaDB fails to start (damaged data directory) | rebuild the data directory and retry, then poll the socket for up to 30 seconds |
| rerun with a MySQL root password already set | switch automatically between password-less and password login |
| rerun with the database already present | `CREATE DATABASE IF NOT EXISTS`, idempotent |
| official download source rate-limits (429) or is unreachable | try mirrors and official sources in order; print manual recovery steps when all fail |
| Salts API unreachable | generate equivalent random Salts locally from `/dev/urandom` |
| backup/media upload returns 413 | already raised: nginx `client_max_body_size 512m` + PHP `upload/post 512M` |
| media library uploads do nothing | `php-gd`/`php-imagick` are installed; Nginx uses the WordPress `try_files` (supports `/wp-json`) |
| media uploads are slow (small VPS) | the mu-plugin prefers GD and skips the 1536/2048 thumbnails; compress originals if it is still slow |
| rerun overwrites the site config | `wp-config.php` is backed up before and restored verbatim after deployment, so the site↔database wiring does not change |
| rerun on an **installed** site | the post-deploy check in §9 accepts `200/301/302` (an installed site returns 200), so it does not fail and abort |
| certificate issuance fails (DNS not live, port 80 blocked, …) | warning only, the HTTP site keeps working; run `reissue` later |
| apt install wants an interactive dialog | `DEBIAN_FRONTEND=noninteractive` throughout |
| `logrotate.service` fails every day | §3 backfills `/etc/mysql/debian.cnf`, §11 rechecks; the unit returns to `inactive` |
| a `.php` file is written into uploads | §6 ships `location ^~ /wp-content/uploads/`: `.php/.phtml/.phar` return 403, static files are unaffected |
| user enumeration (`?author=1`, `/wp-json/wp/v2/users`) | §9 ships a mu-plugin block; normal front-end and admin features keep working |
| XML-RPC used for password spraying | blocked by default in §9; keep it with `WPDK_ALLOW_XMLRPC=1` for the WP mobile app |
| locked out after SSH hardening | hardening only runs when `authorized_keys` already has a key; an interactive run arms a 15-minute auto-rollback (`atrm <job>` to cancel), unattended runs do not |
| 503s from concurrency on a small machine | §5 sets `pm=ondemand` + `max_children` + `max_requests` from RAM |
| hardening steps run again | everything is idempotent: commented lines such as `;pm.max_requests` are recognised, and an existing `define('DISALLOW_FILE_EDIT')` is left alone |

## Backup and restore

Two companion scripts pair with the deployment kit: `wp_backup.sh` produces a
single self-contained archive, and `wp_restore.sh` brings it back on an
equivalent host (same Ubuntu release and package set).

| Part | Contents |
| --- | --- |
| `db.sql` | `mysqldump --single-transaction --all-databases` (schema, data, users and grants) |
| `www.tar.gz` | `/var/www/html` with numeric owners: `wp-config.php`, plugins, themes, uploads, mu-plugins |
| `etc.tar.gz` | nginx (`nginx.conf` + site), PHP (`php.ini`, FPM pool), `debian.cnf`, SSH drop-in, certbot cron, xray unit |
| `le.tar.gz` | `/etc/letsencrypt` (certificates and renewal configuration) |
| `xray.tar.gz` | `config.json` (REALITY private key and UUID), node URL, manage script, binary |
| `manifest.txt` | OS, nginx, PHP, MariaDB, WordPress, plugin and xray versions |

```bash
bash wp_backup.sh                                      # -> /root/wp-backups, 7-day retention
_OUT_DIR_=/data/backups _KEEP_DAYS_=30 bash wp_backup.sh
_SKIP_MAINT_=1 bash wp_backup.sh                       # skip maintenance mode
bash wp_restore.sh /root/wp-backups/wpbackup-<domain>-<timestamp>.tar.gz
```

- The backup puts WordPress into maintenance mode while it runs (usually 5-30
  seconds) so the dump and the file tree are consistent, then removes it.
- The restore expects a **fresh host with the same Ubuntu release**: it installs
  the package set, restores the configuration, imports the database, restores the
  files with their owners and restarts the services.
- Two failure modes found in practice are handled: the restore runs
  `FLUSH PRIVILEGES` after importing the `mysql` schema (otherwise the WordPress
  user gets `Access denied`), and a node URL that still carries the previous
  address is rewritten to the current public IP (REALITY keys are unchanged,
  only the address differs).
- The archive contains the REALITY private key, the database password and the TLS
  private key: treat it as a credential. It is created with `600` permissions;
  keep a copy on another host.

## FAQ

**Q: What if the deployment fails halfway?**
Fix the cause reported by the error (disk, network, security group, …) and run
the script again; every stage is idempotent.

**Q: Can a 1 vCPU / 1G VPS run this?**
Yes. Prefer the Ubuntu 20.04 image, whose components are lighter; newer
releases tend to hang on small machines. Add 1G of swap to lower the OOM risk.

**Q: Can I reinstall a single component?**
No. The script is designed to deploy a whole machine from scratch; to rebuild,
reset the system disk in the cloud console and run it again.

**Q: Is a multi-minute `certbot renew --dry-run` normal?**
Yes. Non-interactive certbot renewals wait a random time (up to 8 minutes)
before contacting the ACME server, to spread the load.

**Q: Can I deploy without a domain?**
Yes. Press Enter at the domain prompt and the public IP is used as the site
address; only the §10 certificate step is skipped. After you point a domain at
the server, run `bash /root/cert_manage.sh reissue` to add HTTPS.

**Q: The script prints the database password — is that safe?**
Credentials only go to the current SSH session, and are also written to
`/root/wp-credentials-<domain>.txt` (mode 600, root-only).
⚠️ If you keep a run log with `bash wp_deploy.sh | tee deploy.log`, **the log
contains the plaintext passwords** (a real lesson: a server had the MariaDB
root password sitting in `/root/wp_deploy_run.log`). `chmod 600` or delete such
logs, and store the passwords in a password manager.

## Security recommendations

### Done automatically by the script

- uploads cannot execute PHP, `server_tokens off`, direct access to
  `readme.html` / `wp-config.php` blocked
- XML-RPC and user enumeration blocked; the dashboard file editor disabled
  (`DISALLOW_FILE_EDIT`)
- `/etc/mysql/debian.cnf` backfilled (fixes the daily `logrotate` failure);
  unattended security updates enabled
- key-only login + brute-force resistance when a public key is detected
  (rollback: `rm -f /etc/ssh/sshd_config.d/99-hardening.conf && sshd -t && systemctl reload ssh`)
- MariaDB listens on localhost only; 3306 is not exposed

### Still up to you

- **WordPress admin password**: set a strong password in the setup wizard and
  enable a **TOTP-only** two-factor plugin (store the recovery codes first).
- **Host-level fallback**: make sure the cloud console VNC/remote access works
  (the only entry point that does not need a key); enable snapshots if you can
- **Backups**: configure a schedule in UpdraftPlus or similar — many sites
  install a backup plugin but never schedule it, which is no backup at all
- **System patches**: standard support for Ubuntu 20.04 ended in May 2025;
  enable the free ESM with `pro attach` or plan an upgrade to 22.04/24.04

## Development conventions (RepoRules)

This repository uses [RepoRules](https://github.com/yanxijian/RepoRules) for
mechanical checks (encoding / line endings / Markdown links); the checker is
vendored in the repository:

```bash
python scripts/repo_rules.py check     # check
python scripts/repo_rules.py fix       # auto-fix (line endings, BOM, …)
git config core.hooksPath .githooks    # once per clone: check before commit
```

- Text files are UTF-8 without BOM; `.sh` / `.md` use LF, pinned by
  `.gitattributes`.
- CI checks out the RepoRules repository and runs `sync --check`: the vendored
  copy fails the build when it falls behind upstream. Update it from a RepoRules
  checkout with `python repo_rules.py sync --root <this repo> --hook`.

## License

[MIT](./LICENSE) © 2026 wordpress-deploy-kit contributors
