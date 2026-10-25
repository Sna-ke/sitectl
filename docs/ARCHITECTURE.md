# How sitectl works

sitectl is a bash program that sets up and manages websites on one Ubuntu
server: nginx, PHP-FPM, a Linux user per site, Let's Encrypt
certificates, and modules for everything else. It is meant to become the
control layer for the server, and the back end of a web control panel
and, later, of central control for several servers (see "Where this is
going" in ROADMAP.md).

This document covers the base code. [MODULES.md](MODULES.md) is the
contract for modules, and [ROADMAP.md](ROADMAP.md) covers the decisions
made and the work planned.


## The server it manages

- Ubuntu 24.04+ (developed against 26.04 on a cloud VPS), nginx, PHP-FPM
  (8.x; the newest installed is used), certbot with its nginx plugin, and
  OpenSSH for SFTP.
- Domains are often behind Cloudflare's proxy. sitectl detects
  Cloudflare's address ranges when checking whether a domain reaches the
  server.
- PHP-FPM runs under **AppArmor in enforce mode** on Ubuntu 26.04, so
  every site user needs AppArmor rules (`/etc/apparmor.d/php-fpm.d/<user>`).
- Docker apps are planned on a separate VM. sitectl doesn't touch Docker
  yet.

### What one site looks like

```
/home/examplecom/                  root:examplecom 750, so the site can't change it
├── public_html/                   example.com's web folder (name is the default_path setting)
├── demo.example.com/              a subdomain on the same user
├── example.net/                   another domain on the same user
├── private/                       700: config, keys, data; usable by PHP, never served
├── logs/                          PHP error log
└── tmp/                           PHP uploads and sessions
```

- **User:** the domain with `.` and `-` removed (`exam-ple.com` →
  `example`), prefixed with `s` if it starts with a digit, cut to 32
  characters. Shell `/usr/sbin/nologin`, UID 1000–59999. `www-data` is
  in the user's group so nginx can read static files.
- **nginx:** `/etc/nginx/sites-available/<domain>` plus a link in
  `sites-enabled`. Each config carries `# managed by sitectl` (or the
  older `created by add-new-site`) and `# Site user: <user>`. Configs
  without the marker are never touched.
- **PHP:** one pool per user (`/etc/php/<ver>/fpm/pool.d/<user>.conf`):
  `pm = ondemand`, socket `/run/php/<user>.sock`, `open_basedir` limited
  to the home folder. Static sites have no pool and return 404 for `.php`.
- **Certificates:** certbot with `--cert-name <domain>`, installed into
  nginx by certbot (this is planned to change: see ROADMAP).
- **SFTP** (sftp module): group `sftponly`, chroot to `/home/<user>`,
  keys in `/etc/ssh/sftp-keys/<user>`, rules in
  `/etc/ssh/sshd_config.d/50-sitectl-sftp.conf`.

### sitectl's own files

| Path | |
|---|---|
| `/usr/local/sbin/sitectl` | The command (`bin/sitectl`) |
| `/usr/local/lib/sitectl/*.sh` | The libraries (`lib/*.sh`) |
| `/usr/local/lib/sitectl/modules/<name>/` | Built-in modules |
| `/usr/local/lib/sitectl/module-template/` | What `modules new` copies |
| `/var/lib/sitectl/modules/<name>/` | Installed modules |
| `/etc/sitectl/sitectl.conf` | Core settings (`CERTBOT_EMAIL`, `DEFAULT_PATH`, `DEFAULT_SITE_TYPE`, `INCLUDE_WWW`, `GET_CERTIFICATE`) |
| `/etc/sitectl/skel/php`, `skel/static` | Skeleton files; `{{DOMAIN}}` and `{{USER}}` are filled in |
| `/etc/sitectl/modules/<m>.conf` | Module settings (and `enabled=`) |
| `/etc/sitectl/secrets/<m>.conf` | Module secrets (700 folder, 600 files, root) |
| `/etc/sitectl/backups/<time>-<name>/` | Everything replaced or removed |
| `/var/log/sitectl.log` | Change log (640 root:adm) |
| `/run/sitectl.lock` | The lock |


## Principles (they explain most of the code)

1. **Stateless.** No database. Everything is read back from the server:
   nginx configs (marker and site user line), pools, groups, certbot's
   folders. A hand edit is never "out of sync".
2. **Nothing is deleted.** Files are moved to the backups (`back_up`).
   The only removals are `unlink` of a checked symlink in `sites-enabled`
   and the strictly matched temporary folder of a module install.
3. **Root never works inside a site's folders.** Files under
   `/home/<user>` are created as the user with `runuser`, so a site
   can't redirect root with symlinks.
4. **Validate, then act.** Domains, usernames and paths are checked
   against strict patterns; system folders are refused. Questions and
   checks all come before the first change.
5. **Test mode** (`-t`) shows every change and makes none. It needs no
   root. The tests prove it by fingerprinting the machine.
6. **One change at a time, and everything logged.** A lock, plus a log
   line per change with the real user behind sudo and the result.
7. **Recover from failure.** A failed redeploy puts the previous configs
   back. Configs are checked (`nginx -t`, `php-fpm -t`, `sshd -t`) before
   reloading.
8. **Secrets** are never shown, never accepted as arguments and never
   logged.
9. **Privilege is declared.** Every command has an access level and a
   scope (`lib/commands.sh`), so a web panel can later call sitectl
   without root of its own.
10. **Plain, commented bash.** Readable for someone maintaining it in vim.


## How a command runs

`bin/sitectl`:

1. Sets `set -euo pipefail` and an ERR trap that prints the failing file
   and line. Exit status 141 (a closed pipe) stops quietly.
2. Finds the libraries: `lib/` next to the script when run from the
   project, otherwise `/usr/local/lib/sitectl`. It sources them in
   order: `ui settings sites subdomains users php nginx certs summary
   redeploy remove list log modules module-settings module-packages
   commands`.
3. `main`:
   1. `load_modules`: finds every module, keeps the newest version of
      each, checks ownership, API and command table, sources
      `module.sh`, and registers module options.
   2. `parse_command_line`: the first word that isn't an option is the
      command. Options can come before or after it. Unknown `--x`
      options are looked up among enabled modules' options.
   3. `authorize_core_command`: looks the command up in the table and
      requires root where its level needs it.
   4. `trap on_exit EXIT`.
   5. Dispatches: `add`, `add-subdomain`, `remove`, `remove-subdomain`,
      `list`, `config`, `modules`, `commands`, `help` and `version`. Any
      other word goes to `run_module_command` if it's an enabled
      module's name.
4. `on_exit` runs on every exit, success or failure:
   - `restore_after_failed_redeploy`
   - removes a module install's temporary folder
   - `log_change_end` (ok, or failed with the exit status)

   It keeps the original exit status. Each step is guarded, so one
   failing can't skip the rest. A bare `return` in a function called from
   an exit trap returns the trapped status, which is why these use
   `return 0`.

### Starting a change

- `start_change` (used by add/remove): root unless `-t`, prints the test
  mode banner, takes the lock, starts the log entry, and loads the core
  settings (running the setup wizard on first use).
- `begin_change` (used by config, modules and module commands): root
  unless `-t`, then the lock and log entry. It is safe to call more than
  once.

### `sitectl add <domain>` (also `add-subdomain`)

`cmd_add`, in order:

1. `apply_options`: command-line options over the settings defaults.
2. `set_domain_paths`: nginx paths, PHP version.
3. `check_for_existing_site`: an existing managed config means **redeploy
   mode** (`REDEPLOY=yes`). The existing user, folder, type and www come
   from the config.
4. For a new site: `use_main_domain_as_parent` (add-subdomain) or
   `find_parent_site`. A subdomain of a site here joins that site's user
   by default, and `--separate-user` gives it its own.
5. `set_user_and_server_names`, then `check_prerequisites`.
6. Questions: `confirm_redeploy` (it lists what will happen, including
   modules' `site_preview`), `choose_subdomain_user` or `choose_user`
   (an existing username: ask, `--use-existing-user` or a new name like
   `examplecom2`).
7. `run_module_hooks site_preparing`. **Nothing has changed before this
   point.**
8. `back_up_old_configs` (redeploy), `create_user`,
   `create_private_folder`, `create_web_root` and `copy_skeleton` (only
   into an empty folder).
9. `create_php_pool`: the pool and AppArmor rules; the old pool is
   retired if the site went static and nothing else uses it.
10. `create_nginx_config`, then `nginx -t` and a reload.
11. `get_certificate` (`certs.sh`):
    - if a certificate for the domain already exists, it's reinstalled
      offline (`certbot install` with explicit paths) first
    - a new one is requested only if names were added or it expires
      within 30 days
    - before requesting, a reachability check: DNS points here, or
      otherwise a temporary hashed file under
      `/.well-known/sitectl-check/` is fetched through the domain
      (Cloudflare-proxied), created and removed as the site user
    - not reachable: the site is **staged** (http only, with steps for
      testing it and changing DNS), unless `--ssl` forces the request
    - a failure is explained: where each name points, firewall, Cloudflare
12. `run_module_hooks site_added`, then `print_summary` (which calls
    `site_summary`).

### `sitectl remove <domain>`

`remove_site`:
- unlinks the `sites-enabled` link and backs up the config
- retires the user's PHP pool and AppArmor rules if no other site uses
  them
- keeps the certificate and pauses its renewal (renames
  `/etc/letsencrypt/renewal/<d>.conf` to `.paused-by-sitectl`); adding
  the site again resumes it, and an expired certificate is deleted
  through certbot
- never removes the user or files

Then `run_module_hooks site_removed`.

### `sitectl list`

Reads every managed config (`site_config_files`) and shows domain, user,
type, www, certificate expiry (from the certificate file; "(needs sudo)"
without root), one column per module with `site_info`, and the web
folder. Subdomains are indented under their main domain. `--json` gives
the same data for programs.


## The libraries

| File | What's in it |
|---|---|
| `bin/sitectl` | Globals, help, `parse_command_line`, `set_domain`/`set_subdomain` (validate and lowercase), `start_change`/`begin_change`, `on_exit`, `cmd_add`, `cmd_remove`, `main` |
| `ui.sh` | `die warn step can_ask ask ask_choice confirm_or_cancel run write_file make_backup_dir back_up disable_site_link`, and the `systemctl` wrapper (keeps the lock's file descriptor out of services) |
| `settings.sh` | Core settings file: `load_config save_config run_config_wizard create_default_skeletons` |
| `sites.sh` | Names and paths, `load_site`, `read_existing_site`, `site_config_files`, `is_site_user`, `check_prerequisites` |
| `subdomains.sh` | Finding the main site; choosing a subdomain's user |
| `users.sh` | `choose_user`, `set_web_root` (validation, reserved folders), `create_user`, `create_private_folder`, `create_web_root`, `copy_skeleton` |
| `php.sh` | `create_php_pool`, `retire_php_pool`, AppArmor rules |
| `nginx.sh` | `create_nginx_config` (IPv6 listen only if the server has IPv6) |
| `certs.sh` | Reachability checks, existing-certificate reinstall, staging, failure explanations, pause/resume renewal |
| `redeploy.sh` | Redeploy detection and confirmation, backups, `restore_after_failed_redeploy` |
| `remove.sh` | `remove_site` |
| `summary.sh` | `print_summary` |
| `list.sh` | `cmd_list`, `json_string`, `align_columns` |
| `log.sh` | `take_lock`, `log_change_start` (redacts inline `--sftp-key` values), `log_change_end` |
| `modules.sh` | Versions, `read_manifest`, `safe_to_load`, `load_modules`, module options, `run_module_hooks`, `modules_with_site_info` |
| `module-settings.sh` | Settings schema, `module_get`/`module_set`, secrets, the wizard, `cmd_config` |
| `module-packages.sh` | `check_package`, unpacking, `sitectl modules` (list, info, enable, disable, install, uninstall, pack, new) |
| `commands.sh` | The command table, access levels, `require_level`, `authorize_core_command`, `run_module_command`, `sitectl commands` |

### Important globals

| Variable | |
|---|---|
| `SITECTL_VERSION`, `SITECTL_MODULE_API` | `0.3.0`, `1` |
| `SITECTL_LIB` | Where the libraries are |
| `SUBCOMMAND`, `ARGS[]`, `ORIGINAL_ARGS[]` | The parsed command line |
| `DRY_RUN`, `ASSUME_YES` | `-t`, `--yes` |
| `DOMAIN`, `MAIN_DOMAIN`, `SITE_USER`, `HOME_DIR`, `WEB_ROOT`, `SITE_TYPE`, `PHP_VERSION` | The site being worked on |
| `NGINX_CONFIG`, `NGINX_ENABLED_LINK`, `PHP_POOL_CONFIG` | Its files |
| `REDEPLOY`, `BACKUP_DIR` | Redeploy mode; this change's backup folder |
| `MODULES[]`, `MODULE_DIR[]`, `MODULE_VERSION[]`, ... | Loaded modules |
| `MODULE_OPTIONS[]` | Module options given on the command line |
| `CMD_NAME`, `CMD_LEVEL`, `CMD_SCOPE`, `CMD_USAGE` | Set by `find_command` |


## Access levels and the future API

`lib/commands.sh` holds one table of every command, core and module:

```
sitectl commands          # table
sitectl commands --json   # for programs
```

| Level | |
|---|---|
| `read` | No root needed |
| `read-root` | Read-only, needs root |
| `site-change` | Changes one site only |
| `server-change` | Changes the server (users, shared config, settings) |
| `server-admin` | Can lead to new code running as root (module installs) |

Today the table is used to require root and, for module commands, to
check arguments, check the domain and take the lock. It's the groundwork
for a web panel that has no root of its own. The plan, not yet built:

- The panel runs as its own user (e.g. `sitectl-panel`, with its own PHP
  pool), **not** `www-data`, which is in every site's group.
- One sudo rule:
  `sitectl-panel ALL=(root) NOPASSWD: /usr/local/sbin/sitectl api`.
- `sitectl api` reads one JSON request on stdin, for example
  `{"command": "sftp.add-key", "args": ["example.com", "ssh-ed25519 ..."], "on_behalf_of": "alice"}`,
  and returns JSON. It never prompts and never uses a shell. Secrets come
  in the JSON, never as arguments.
- `/etc/sitectl/api.conf` sets a ceiling per calling Unix user (the one
  behind sudo), e.g. `sitectl-panel: max=site-change`, and can deny
  named commands. `server-admin` is never allowed through the API by
  default.
- The panel does the per-person role checks (Alice manages example.com),
  using each command's level and scope. sitectl enforces the ceiling as
  a second line of defence.
- The log records both: "sitectl-panel for alice".
- For several servers, the same JSON interface runs behind an agent on
  each one.

Core commands are classed conservatively for now (`add` and `remove`
are `server-change` because they create or retire users and pools).
Site-scoped variants can be added later.


## Testing

`tests/run-tests.sh` (97 tests in 0.3.0) runs **only on a throwaway VM or
container**: it creates users, sites, SSH settings and fake
certificates, and refuses to start without
`SITECTL_TEST_ON_THROWAWAY_MACHINE=yes`.

```bash
sudo SITECTL_TEST_ON_THROWAWAY_MACHINE=yes tests/run-tests.sh
# where /usr/bin/certbot is broken or elsewhere:
sudo CERTBOT_REAL=/path/to/certbot SITECTL_TEST_ON_THROWAWAY_MACHINE=yes tests/run-tests.sh
```

- `tests/shims/systemctl` stands in for systemd (containers without
  it): it reloads nginx, PHP-FPM and a test sshd directly.
- `tests/shims/certbot` runs the real certbot against an address where
  no Let's Encrypt server listens, with its own folders, and logs each
  call. No real certificate can be requested.
- Names are unique per run, so the suite can be rerun.
- SFTP tests run if `sshd` and `sftp` exist (a test sshd on port 2299).

`tools/release.sh` checks syntax, writes the built-in modules'
`CHECKSUMS`, and builds `../sitectl-<version>.tar.gz`. Before a release,
also run `shellcheck` over the program. Concatenate `bin/sitectl` and
the libraries so shellcheck sees them together; the commands are in
ROADMAP.md.
