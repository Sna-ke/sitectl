# sitectl

Set up and manage websites on an Ubuntu server running nginx and PHP-FPM:
one command per job, each site with its own Linux user, PHP pool,
certificate and (optionally) SFTP login, with modules for the rest.

```
sudo sitectl add example.com                    # a PHP site with its own user
sudo sitectl add-subdomain example.com demo     # demo.example.com, same user
sitectl list                                    # every site, with certificate dates
sudo sitectl remove example.com                 # take a site down (files kept)
```

Version 0.3.0. Formerly the single script `add-new-site`; sites made with
that are picked up automatically.

More in [`docs/`](docs/): [how sitectl works](docs/ARCHITECTURE.md),
[writing modules](docs/MODULES.md), [status and what's
next](docs/ROADMAP.md), and [the 0.4 design](docs/DESIGN-0.4.md).


## Installing

On the server (Ubuntu 24.04 or later):

1. **Install what sitectl uses**, if you haven't already:

   ```bash
   sudo apt install nginx php-fpm certbot python3-certbot-nginx curl openssl
   sudo apt install openssh-server        # only needed for --sftp
   ```

2. **Copy the package to the server and unpack it.** From your computer:

   ```bash
   scp sitectl-0.3.0.tar.gz ubuntu@SERVER_IP:
   ssh ubuntu@SERVER_IP
   tar xzf sitectl-0.3.0.tar.gz
   cd sitectl-0.3.0
   ```

3. **Install it:**

   ```bash
   sudo ./install.sh
   ```

   This puts the command in `/usr/local/sbin/sitectl` and its library files
   in `/usr/local/lib/sitectl`. It lists anything missing rather than
   installing it, and, if you used `add-new-site` before, moves its settings
   from `/etc/add-new-site` to `/etc/sitectl` (once) and tells you how to
   retire the old command.

4. **First run:** `sudo sitectl config` asks for your Let's Encrypt email
   and default settings, and creates the skeleton folders. (Any first
   `add` does this too.)

**Upgrading:** unpack the new version and run `sudo ./install.sh` again.
Your settings and sites aren't touched. Files the new version no longer
has are moved to `/etc/sitectl/backups/` (from 0.2: `sftp.sh`, which is
now the sftp module). Modules you installed yourself stay as they are.

**Uninstalling:** `sudo ./uninstall.sh` removes the command and its library
files only. Sites keep running; settings, backups and the log stay.

**Keeping it in git** is a good idea as it grows: the whole project is
plain text, and `install.sh` installs from whatever is checked out.


## Commands

| Command | What it does |
|---|---|
| `sitectl add <domain>` | Add a site. Run it again to **redeploy**: configs are rebuilt, files are kept. |
| `sitectl add-subdomain <domain> <name>` | Add `<name>.<domain>` to an existing site's user. |
| `sitectl remove <domain>` | Disable a site and set its configs aside. Never deletes the user or files. |
| `sitectl remove-subdomain <domain> <name>` | Same, for a subdomain. |
| `sitectl list [<domain>] [--json]` | All sites (or one site and its subdomains): user, type, certificate expiry, SFTP, web folder. |
| `sitectl config` | Walk through sitectl's own settings. |
| `sitectl config <module>` / `config show` / `get` / `set` / `set-secret` / `unset` | Module settings: see [Settings and modules](#settings-and-modules). |
| `sitectl modules ...` | List, enable, disable, install and uninstall modules: see [Modules](#modules). |
| `sitectl sftp ...` | SFTP logins and keys: see [SFTP](#sftp). |
| `sitectl commands [--json]` | Every command with its access level (read, site-change, server-change, ...) and scope. |
| `sitectl help` | All options. |

Options for `add` / `add-subdomain`:

| Option | |
|---|---|
| `--php` / `--static` | PHP site, or plain HTML |
| `--www` / `--no-www` | Also serve `www.<domain>` (subdomains default to no) |
| `--ssl` / `--no-ssl` | Get a certificate or not; `--ssl` also forces a request when the domain doesn't reach the server yet |
| `--path PATH` | Web folder, relative to the user's home or absolute |
| `--user NAME` | Site user; an existing one gets this domain added to it |
| `--use-existing-user` | If the username made from the domain exists, add to it without asking |
| `--separate-user` | Give a subdomain its own user |
| `--sftp`, `--sftp-key KEY` | SFTP login for the site user, jailed to its home; KEY is a `.pub` file or the key itself (from the sftp module) |

Modules can add options of their own; `sitectl help` lists the ones
enabled modules add.

For every command that changes things: `-y`/`--yes` answers "are you sure?",
and `-t`/`--dry-run` shows what would happen without changing anything
(and works without sudo). Options can go before or after the command.


## How sites are laid out

```
/home/examplecom/                  owned by root, so the site can't change it
├── public_html/                   example.com
├── demo.example.com/              a subdomain on the same user
├── example.net/                   another domain on the same user
├── private/                       config, keys, data: usable by the site's code, never served
├── logs/                          PHP error log
└── tmp/                           PHP uploads and sessions
```

- The username is the domain without dots and hyphens (`example.com` →
  `examplecom`). It has no login shell.
- PHP runs as the site user, in its own PHP-FPM pool, limited to its home
  folder. Sites on different users can't read each other's files.
- From a site's code, the private folder is next door:
  `require __DIR__ . '/../private/config.php';`
- Ubuntu confines PHP-FPM with AppArmor; sitectl adds a rules file per user
  in `/etc/apparmor.d/php-fpm.d/` so PHP can use that user's folders only.
- Static sites never serve `.php` files, so source code can't leak.


## Certificates and moving sites

- A new site gets a Let's Encrypt certificate once its domain reaches this
  server. sitectl checks first: by DNS, or (behind Cloudflare's proxy) by
  fetching a temporary file through the domain.
- **Moving a site from another server:** run `sitectl add` first. Until DNS
  points here the site is *staged*: served over http, no certificate
  requested, and sitectl prints how to test it (a `curl` command and a
  hosts-file line) and what DNS to change. After switching DNS, run
  `sudo sitectl add example.com --yes` to get the certificate.
- A **redeploy** reinstalls the existing certificate without asking Let's
  Encrypt; a new one is only requested if a name was added or it expires
  within 30 days.
- **Renewal** is done by certbot's own timer (`systemctl status certbot.timer`).
  Let's Encrypt no longer emails expiry warnings, so `sitectl list` shows
  every certificate's expiry date.
- **Removing** a site keeps its certificate and pauses its renewal; adding
  the site again reuses it. Expired certificates are deleted on removal.


## SFTP

The sftp module (built in, on by default) gives site users SFTP logins,
jailed to their home folder, with uploads owned by the site user.

```bash
sudo sitectl add example.com --sftp-key ~/.ssh/id_ed25519.pub   # new site, or an existing one
sitectl sftp status                                 # every SFTP user and their key count
sitectl sftp status example.com                     # that site's keys, by fingerprint
sudo sitectl sftp add-key example.com laptop.pub    # allow another key
sudo sitectl sftp remove-key example.com laptop     # by comment, fingerprint or whole key
sudo sitectl sftp disable example.com               # stop SFTP (keys are kept)
sudo sitectl sftp enable example.com                # ...and turn it back on
```

The first time, sitectl sets up the `sftponly` group and SSH rules
(`/etc/ssh/sshd_config.d/50-sitectl-sftp.conf`), testing SSH's config before
reloading it. Keys live in `/etc/ssh/sftp-keys/<user>`, owned by root; a
removed key's old file goes to the backups.

Connect to the server's **IP address** (Cloudflare's proxy doesn't pass
SSH). If your router has intrusion prevention (e.g. UniFi), set your SFTP
app to use one connection, or several at once can look like an SSH scan.


## Settings

Each module describes its own settings, and sitectl handles asking for,
checking, storing and showing them the same way for all of them.
sitectl's own settings are the built-in `core` module.

```bash
sitectl config show                               # every module's settings
sudo sitectl config dns                           # walk through one module's settings
sudo sitectl config set core.default_site_type static
sudo sitectl config set-secret dns.api_token      # type it (hidden)...
sudo sitectl config set-secret dns.api_token < token.txt    # ...or pipe it in
```

- **Settings and secrets are kept apart.** Settings live in
  `/etc/sitectl/modules/<module>.conf`. Secrets (API keys, passwords) live
  in `/etc/sitectl/secrets/<module>.conf`, readable by root only. Secrets
  are never shown (`show` only says whether one is set), never accepted on
  the command line (it would land in your shell history), and never
  logged.
- **Every change** is validated against the setting's type, backed up
  first, logged, and locked like any other change.


## Modules

Everything beyond plain sites (SFTP now; DNS, databases, mail, Docker
later) comes as a **module**. sitectl ships its default modules, and each
module has its own version, so a module can be updated without a new
sitectl.

```bash
sitectl modules                                   # what's here: version, on/off, built-in or installed
sitectl modules info sftp                         # its settings and commands
sudo sitectl modules install database-1.2.0.tar.gz   # or a folder: database.pkg/
sudo sitectl modules enable database              # asks for missing settings, runs its check
sudo sitectl modules disable database             # settings are kept
sudo sitectl modules uninstall database           # the files go to the backups
```

- **Built-in and installed.** Modules that come with sitectl are in
  `/usr/local/lib/sitectl/modules/`; ones you install go in
  `/var/lib/sitectl/modules/`. If both have a module, the newer version is
  used, so you can install a fix before the next sitectl release, and a
  sitectl upgrade that ships a newer one takes over again.
- **Installing checks the package:** a `module.conf` saying what it is and
  which sitectl it needs; every file listed in `CHECKSUMS` and matching it;
  no links or special files; the modules it depends on present. It shows
  whether it's new, an upgrade, a reinstall or a downgrade, and asks first.
  The previous version goes to the backups. (Checksums catch damage and
  accidental edits; they don't prove who made a package, so only install
  modules you trust: they run as root.)
- **Module files must be owned by root** and not writable by anyone else,
  or they aren't loaded.
- **What a module can do:** add settings; add options to `sitectl add`
  (like `--sftp-key`); act before and after a site is added or removed
  (a failure after the site is set up is reported, but never undoes it);
  add a column to `sitectl list`; and add its own commands
  (`sitectl sftp ...`).

**A package** is a folder:

```
database.pkg/
├── module.conf     name, version, description, api, requires_sitectl, depends, enabled_by_default
├── module.sh       the code: module_database_settings, hooks, commands
├── README.md       optional
├── CHECKSUMS       written by `sitectl modules pack`
└── ...             anything else it needs (templates, providers/)
```

- **Every command is declared** with an access level and scope, and
  sitectl checks the arguments, requires sudo where needed, takes the
  lock and logs the change before the module's code runs. This is the
  groundwork for a web panel that calls sitectl without root of its own.

**Writing your own** (the full guide is [docs/MODULES.md](docs/MODULES.md)):

```bash
sitectl modules new hello                 # makes ./hello.pkg from the template
vim hello.pkg/module.sh                   # the template explains each part
sitectl modules pack hello.pkg            # writes CHECKSUMS, makes hello-1.0.0.tar.gz
sudo sitectl modules install hello-1.0.0.tar.gz
```

For a new release, bump `version` in `module.conf` and pack it again.


## Where things are

| | |
|---|---|
| `/etc/sitectl/sitectl.conf` | Default settings (`sitectl config` to change) |
| `/etc/sitectl/skel/php`, `skel/static` | Files copied into new sites; `{{DOMAIN}}` and `{{USER}}` are filled in |
| `/etc/sitectl/backups/` | Every config sitectl replaced or removed. Nothing is deleted. |
| `/etc/sitectl/modules/`, `/etc/sitectl/secrets/` | Module settings, and their secrets (root only) |
| `/usr/local/lib/sitectl/modules/` | Modules that come with sitectl |
| `/var/lib/sitectl/modules/` | Modules you installed |
| `/var/log/sitectl.log` | Every change: when, who (behind sudo), the command, and the result |
| `/usr/local/lib/sitectl/*.sh` | The code, one file per area |
| `/usr/local/lib/sitectl/module-template/` | What `sitectl modules new` copies |


## Design notes

- **No database.** Everything is read from the server itself: the nginx
  configs (each carries a "managed by sitectl" marker and its site user),
  PHP pools, AppArmor files and certbot's records. So it's always right,
  even after a hand edit, and configs sitectl didn't write are never touched.
- **Nothing is deleted.** Replaced configs go to the backup folder; a failed
  redeploy puts the previous ones back automatically.
- **One change at a time.** A lock stops two changes running together.
- **Root never works inside a site's folders.** Files there are created as
  the site user, so a site can't trick sitectl with symlinks.


## Developing and testing

The tests rebuild the scenarios sitectl was developed against. **Only run
them on a throwaway VM or container**, never on a real server:

```bash
sudo SITECTL_TEST_ON_THROWAWAY_MACHINE=yes tests/run-tests.sh
```

Run `bin/sitectl` straight from the project folder to try changes before
installing them; it uses the `lib/` next to it.

`tools/release.sh` makes a release: it checks the syntax, writes
`CHECKSUMS` for the bundled modules, and builds `sitectl-<version>.tar.gz`.
