# Writing sitectl modules

Everything sitectl does beyond plain sites comes as a module: SFTP today;
DNS, databases, mail, Docker and others later. This guide is the complete
contract between sitectl and a module (module API 1). Read
[ARCHITECTURE.md](ARCHITECTURE.md) first for how sitectl itself works.

The `sftp` module (`lib/modules/sftp/`) is the working reference, and
`sitectl modules new <name>` starts a module from the template
(`lib/module-template/`).


## 1. The package

A module is a folder (a "package"), usually called `<name>.pkg` while
you work on it:

```
database.pkg/
├── module.conf     what it is (required)
├── module.sh       the code (required)
├── README.md       for people (optional)
├── CHECKSUMS       sha256 of every other file (written by `sitectl modules pack`)
└── ...             anything else: templates, providers/, files/
```

Installed packages are copied to `/var/lib/sitectl/modules/<name>/`
(root-owned, folders 755, files 644). Modules that ship with sitectl are
in `/usr/local/lib/sitectl/modules/<name>/`. If both have one, the
**higher version** is loaded. A module reaches its own files with
`"$(module_dir <name>)/templates/..."`.

### module.conf

```
name=database
version=1.0.0
description=MariaDB databases and users for sites
api=1
requires_sitectl=0.3.0
depends=
enabled_by_default=no
```

| Key | Rules |
|---|---|
| `name` | `^[a-z][a-z0-9_]{0,31}$`, not `core`. It must match the folder name once installed, and it's the prefix of every function. |
| `version` | `1`, `1.2` or `1.2.3`, compared with `sort -V`. Bump it on every release. |
| `description` | One line. Shown in `sitectl modules`. |
| `api` | Must equal sitectl's `SITECTL_MODULE_API` (currently `1`), or the module isn't loaded. |
| `requires_sitectl` | The oldest sitectl it works with. |
| `depends` | Other module names, separated by spaces. They must be installed (and enabled before this one can be). |
| `enabled_by_default` | `yes`: on as soon as it's installed. `no`: needs `sitectl modules enable` (use this when it needs settings first). |

The file is read with `read_value`, never sourced, so it can't run code.

### Install-time checks

`sitectl modules install` refuses a package that:
- contains symlinks or special files
- has a missing or bad `module.conf`, or a wrong `api` or `requires_sitectl`
- has a file not listed in `CHECKSUMS`, or one that doesn't match it
- depends on a module that isn't installed

At load time, sitectl also skips any module folder with a file that isn't
owned by root or is writable by group or others. It skips a module whose
command table is invalid too (see section 5).


## 2. module.sh

`module.sh` is sourced into sitectl, as root, when sitectl starts. So:

- **Define functions only.** No code at the top level, beyond setting
  constants (e.g. `SFTP_GROUP="sftponly"`).
- **Prefix everything** with the module name: `module_<name>_*` for the
  interface below, and `<name>_*` for your own helpers and globals. Names
  share one namespace with sitectl and every other module.
- `set -euo pipefail` is on, and an ERR trap prints the failing file and
  line.

The interface is a set of optionally defined functions:

| Function | Required | Purpose |
|---|---|---|
| `module_<n>_settings` | yes | Settings schema (may print nothing) |
| `module_<n>_check` | | Check the settings work; runs on `modules enable` |
| `module_<n>_options` | | Options added to `sitectl add` / `add-subdomain` |
| `module_<n>_site_preview` | | Lines for the "Redeploying will:" list |
| `module_<n>_site_preparing` | | Before anything changes; can stop the change |
| `module_<n>_site_added` | | After a site is added or redeployed |
| `module_<n>_site_summary` | | Lines for the summary at the end of `add` |
| `module_<n>_site_removed` | | After `sitectl remove` |
| `module_<n>_site_info` | | A column in `sitectl list` |
| `module_<n>_commands` | with `_command` | Command table: level, scope, usage |
| `module_<n>_command` | | Runs `sitectl <n> <command> ...` |

A module that is disabled loads, but sitectl uses none of these:
- its options are unknown to the command line
- its hooks don't run and its list column isn't shown
- its commands refuse to run


## 3. Settings

```bash
module_database_settings() {
  cat <<'EOF'
engine|choice:mariadb/mysql|mariadb|yes|Which server
host|text|localhost|yes|Database host
admin_password|secret||yes|Password for the admin account
backups|yesno|yes|no|Back up databases nightly
EOF
}
```

Each line has five fields: `key|type|default|required|description`.

- **key:** `^[a-z][a-z0-9_]*$`.
- **types:** `text`, `secret`, `yesno`, `email`, `number`, `path` and
  `choice:a/b/c`. sitectl validates values against the type.
- **required:** `yes` means `modules enable` asks for the setting (or
  refuses without a terminal) unless it has a value or a default.
- `enabled` is reserved. sitectl stores the on/off state under it.

Settings are stored in `/etc/sitectl/modules/<n>.conf` (644). Secrets go
in `/etc/sitectl/secrets/<n>.conf`: the folder is 700, the file 600,
both root.

Reading a setting: `module_get <n> <key>` prints the stored value or the
default. It works for secrets too, when running as root.

**Secrets rules (do not break these):**
- never print or log a secret, and never put one in a command's arguments
  (they show in `ps`)
- pass secrets to programs through a file only root can read, or on stdin
- people set secrets with `sitectl config set-secret <n>.<key>`, typed
  hidden or piped in, never on the command line

`module_<n>_check` runs on `sitectl modules enable`, after required
settings are filled in. Print a line or two. A non-zero return means the
module isn't enabled. Use it to test credentials (an API call, a database
login).


## 4. Options for `sitectl add`

```bash
module_sftp_options() {
  cat <<'EOF'
--sftp||Allow SFTP uploads as the site user
--sftp-key|KEY|Public key allowed to log in: a .pub file, or the key in quotes
EOF
}
```

Each line is `--flag|VALUE-NAME|description`. An empty `VALUE-NAME`
means a switch that takes no value. Given options are in
`MODULE_OPTIONS[--flag]`: the value, or `yes` for a switch. Read them
with `${MODULE_OPTIONS[--flag]:-}`. Flags must be unique across modules
and must not clash with sitectl's own. The option help appears in
`sitectl help`, tagged with the module's name.

> If an option's value can be a secret, it must not be a command-line
> option. Use a setting, or a command that reads the value from stdin.
> (`--sftp-key` values are public keys; the log still redacts inline ones.)


## 5. Commands and access levels

Commands are how a module does things outside of `add`/`remove`:
`sitectl sftp add-key ...`. Every command is **declared**, so sitectl
(and later a web panel, through `sitectl api`) knows what it needs and
what it can do.

```bash
module_sftp_commands() {
  cat <<'EOF'
status|read|site?|[<domain>]|SFTP logins and their keys
enable|server-change|site|<domain> [<key>]|Allow SFTP for the site's user
add-key|site-change|site|<domain> <key>|Allow a key (.pub file, or the key in quotes)
remove-key|site-change|site|<domain> <which>|Remove a key by fingerprint, comment, or the whole key
disable|server-change|site|<domain>|Stop SFTP for the site's user (keys kept)
EOF
}

module_sftp_command() {
  local action="$1"; shift
  case "$action" in
    status)     sftp_status "$@" ;;
    enable)     sftp_enable "$@" ;;
    add-key)    sftp_add_key "$@" ;;
    remove-key) sftp_remove_key "$@" ;;
    disable)    sftp_disable "$1" ;;
  esac
}
```

Each line has five fields: `name|level|scope|usage|description`. The
command's full name is `<module>.<name>` (`sftp.add-key`), which is what
`sitectl commands` lists and what the future API will accept.

### Access levels

Pick the **lowest level that is true** for everything the command can do.
The level controls whether sudo is needed and whether the command is
logged, and it will cap what a web panel may ever ask for.

| Level | Means | sitectl does |
|---|---|---|
| `read` | Only reads, and works without root (may show less) | nothing extra |
| `read-root` | Only reads, but needs root (root-only files) | requires root |
| `site-change` | Changes **one site** only: its own files, keys, its database. Nothing shared, no new users. | requires root (unless `-t`), takes the lock, logs |
| `server-change` | Changes the server: users, groups, shared configs (sshd, nginx main config), settings, services | same |
| `server-admin` | Can lead to new code running as root (installing modules, editing hooks, anything that runs a program a caller chose) | same; the panel will never be allowed this |

When unsure between two levels, choose the higher one. For example,
`sftp enable` is `server-change` because the first time it creates the
`sftponly` group and SSH rules, even though usually it only touches one
site.

### Scope

| Scope | Means |
|---|---|
| `server` | Not about one site |
| `site` | The first argument is a domain, and the command only affects that site (and its user) |
| `site?` | A domain is optional. With one it acts like `site`; without one it covers every site (counts as server-wide) |

For `site` and `site?` with a domain, sitectl checks the domain's syntax
before your code runs. Your code still calls `load_site "$1"`, which
stops with a clear error if the site isn't managed by sitectl.

The scope is what lets a panel grant a command per site ("Alice may run
`sftp.add-key` on example.com"), so it must be truthful: a `site`
command may not touch another site.

### What sitectl does before calling `module_<n>_command`

1. Looks up `<module>.<command>` in your table. Unknown commands are
   refused, and `help` (or no command) prints help made from the table.
2. Checks the argument count against `usage`: `<x>` is required, `[<x>]`
   optional, and a trailing `...` allows any number more.
3. Checks the access level: root where needed.
4. For a `site`-scoped command, checks the domain.
5. For a change level: `begin_change`, which takes the lock and starts
   the change-log entry. Its result (ok or failed) is logged on exit.
6. Calls `module_<n>_command <command> <args...>`.

Within your command, honour test mode (use `run` and `write_file`, and
check `$DRY_RUN`), ask with `confirm_or_cancel` before anything
destructive (`--yes` answers it), and back files up with `back_up`
before replacing them.

Usage text is for people and for argument counting only. Validate each
argument's content yourself (keys, names, paths).


## 6. Hooks around adding and removing sites

During `sitectl add` (and redeploys), `add-subdomain` and `remove`,
sitectl calls each enabled module's hooks in module-name order. These
variables are set:

| Variable | |
|---|---|
| `DOMAIN` | The site (lowercase, validated) |
| `SITE_USER`, `HOME_DIR` | Its Linux user and `/home/<user>` |
| `WEB_ROOT` | Its web folder |
| `SITE_TYPE` | `php` or `static` |
| `REDEPLOY` | `yes` when the site already existed |
| `DRY_RUN` | `yes` in test mode: show, change nothing |
| `MODULE_OPTIONS[...]` | Options given on the command line |

| Hook | When | Runs in | A failure |
|---|---|---|---|
| `site_preview` | listing what a redeploy will do, before confirming | sitectl | stops the command (only print in it) |
| `site_preparing` | after questions, before anything changes: validate options, ask for what you need | sitectl | **stops the whole change safely**: use `die` here for bad input |
| `site_added` | after the site is set up | a subshell with `set -e` | is reported; the site stays |
| `site_summary` | printing the summary at the end | a subshell | is reported |
| `site_removed` | after `sitectl remove` | a subshell | is reported |

- `site_preview` and `site_preparing` run in sitectl's own shell, so they
  can set globals (e.g. a parsed key) for later. `site_added`,
  `site_summary` and `site_removed` run in subshells, so they **cannot
  pass variables on**: recompute what you need from the server.
- Do the risky work in `site_added`. Anything that can fail because of
  bad input should already have failed in `site_preparing`, before any
  change was made.

### A column in `sitectl list`

`module_<n>_site_info <domain> <user>` prints one short word (`yes`,
`no`, a count). Stderr is discarded and an empty result shows as `-`. It
runs once per site, **without root** when the user didn't use sudo, so
it must be quick and must not fail without root. Print `?` if it can't
tell.


## 7. Helpers a module can use

These are stable for API 1.

| Helper | |
|---|---|
| `die "msg"` | Print `Error: msg` and exit 1 (runs the exit handler: restore, log) |
| `warn "msg"`, `step "Title"` | Messages |
| `can_ask` | True if a person is there to answer (a terminal on stdin) |
| `ask "Question" var_name "default"` | Ask and store the answer in `var_name` (only when `can_ask`) |
| `ask_choice "Question" var_name "default" a b c` | The same, limited to the choices |
| `confirm_or_cancel "Do X?"` | Yes/no; `--yes` answers yes and test mode doesn't ask; with no terminal and no `--yes`, stops |
| `run cmd args...` | Run a command, or print it in test mode. Never through a shell. |
| `write_file /path <<EOF` | Write a file from stdin, or show it in test mode |
| `back_up /path` | Move a file or folder into this change's backup folder (`$BACKUP_DIR`) |
| `load_site <domain>` | Load an existing site: `DOMAIN`, `SITE_USER`, `HOME_DIR`, `WEB_ROOT`, `SITE_TYPE`, `NGINX_CONFIG`; stops if it isn't managed by sitectl |
| `site_config_files` | Every managed site's nginx config, one per line |
| `site_user_from_config <file>` | The site user from a config |
| `other_domains_for_user <user>` | The other domains on that user |
| `is_site_user <user>` | True if the user looks like a sitectl site user |
| `module_get <m> <key>`, `module_enabled <m>`, `module_dir <m>` | Settings and state |
| `read_value <file> <key>` | Read `key=value` from a file without sourcing it |
| `align_columns` | Tab-separated rows on stdin to aligned columns |
| `json_string "text"` | A JSON string literal |
| `systemctl ...` | Use it as normal; sitectl's wrapper keeps the lock out of services |

Avoid touching the core's globals other than reading the ones above. Never
change `DRY_RUN`, `ASSUME_YES` or `BACKUP_DIR`.


## 8. Rules every module follows

These are the project's safety rules; sitectl's own code follows them too.

1. **Nothing is deleted.** Replaced or removed files go to the backups
   with `back_up`. No `rm -rf`. If something must really be removed, use
   `unlink` on one checked path.
2. **Root never writes inside a site's folders.** Anything under
   `/home/<user>` is written as that user (`runuser -u "$SITE_USER" --
   ...`), so a site can't trick root with symlinks. Refuse symlinks
   where a real file is expected.
3. **Validate every input** (domain, key, name, path) with a strict
   pattern before using it, and quote every variable. Never build shell
   strings from input. Never `eval`.
4. **Test mode changes nothing.** Every change goes through `run` or
   `write_file`, or is guarded by `[[ "$DRY_RUN" != yes ]]`. The tests
   fingerprint the machine to prove it.
5. **Stateless.** Read the truth from the server (configs, groups,
   files), not from a record of what you did. A module may keep its own
   settings, but never a separate list of sites.
6. **Check configs before reloading** (`nginx -t`, `sshd -t`,
   `php-fpm -t`), and keep the old file to put back if the check fails.
7. **Secrets** follow section 3.
8. **Ask before anything destructive** (`confirm_or_cancel`); work
   unattended with `--yes`.
9. **Clear errors that say what to do next**, with example commands
   using `example.com`.
10. **Don't over-build.** Only what's needed now, and readable code with
    comments that say why.


## 9. Providers (for modules with several backends)

Some modules do one job through different services: DNS through
Cloudflare, BIND (RFC 2136) or by hand. The convention (not yet used by a
shipped module):

```
dns.pkg/
├── module.sh            the job: commands, hooks, choosing a provider
└── providers/
    ├── manual.sh        dns_provider_manual_set_record, ..._delete_record, ...
    ├── cloudflare.sh
    └── rfc2136.sh
```

- The module defines the provider interface: a fixed list of functions
  each provider implements, named `<module>_provider_<provider>_<action>`.
- Which provider is used is a setting, e.g.
  `provider|choice:manual/cloudflare/rfc2136|manual|yes|...`. Per-domain
  choice can be added where the job needs it; for DNS it would be worked
  out from the domain's NS records.
- `module.sh` sources only the chosen provider's file:
  `source "$(module_dir dns)/providers/$provider.sh"`. The provider name
  must be validated against the choice list first.
- Each provider's own settings are prefixed in the module's schema
  (`cloudflare_api_token|secret|...`).

The same pattern is planned for the web server itself (nginx now, Apache
later) inside sitectl's core.


## 10. Making, testing and releasing a module

```bash
sitectl modules new database                 # ./database.pkg from the template
vim database.pkg/module.conf database.pkg/module.sh
sitectl modules pack database.pkg            # writes CHECKSUMS, makes database-1.0.0.tar.gz
sudo sitectl modules install database-1.0.0.tar.gz
sudo sitectl config database                 # fill in settings
sudo sitectl modules enable database         # runs _check
sitectl modules info database                # settings and commands
sitectl commands | grep database             # levels and scopes as sitectl sees them
sudo sitectl -t database <command> ...       # test mode first
```

- For a new release, bump `version` and pack again. Installing a higher
  version is an upgrade, and the old one goes to the backups.
- Built-in modules (in `lib/modules/`) get their `CHECKSUMS` written by
  `tools/release.sh`.
- Add tests to `tests/run-tests.sh`, which runs only on a throwaway
  machine:
  - a test-mode run that changes nothing
  - a real run
  - each refusal
  - each command's access level as a non-root user (`runuser -u nobody`)

### Checklist before shipping a module

- [ ] `module.conf` complete; `api=1`; version bumped
- [ ] Every function and global prefixed with the module name
- [ ] Each command has the lowest true level and a truthful scope
- [ ] Bad input is caught in `site_preparing` or before any change
- [ ] Test mode (`-t`) changes nothing
- [ ] Nothing is deleted; replaced files are backed up
- [ ] No root writes inside `/home/<user>`
- [ ] Secrets never printed, logged or put on a command line
- [ ] `site_info` works without root
- [ ] README says what it does, its settings and its commands
- [ ] Tests added and passing; `shellcheck` clean
