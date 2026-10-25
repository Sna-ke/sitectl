# sitectl: status, decisions and what's next

This file carries the project from one working session to the next.
The code lives in the GitHub repository `Sna-ke/sitectl`. To start a new
session:

1. give it the repository, with push access
2. point it at this file, `ARCHITECTURE.md` and `MODULES.md`, plus any
   design notes for the work at hand (`DESIGN-0.4.md` for 0.4), all in
   `docs/`
3. give it the request

Then ask it to read the docs and the relevant code before changing
anything.

Work happens one branch and one pull request per piece of work, so each
change is reviewed before it's merged. Commit messages say what changed
and why. The tests run in the session's own disposable container (see
"Development notes").


## Where this is going

sitectl started as a script to add one website, and is becoming the
**control layer for a web server**: the one program that knows how the
server is set up and is allowed to change it. Three layers are planned
on top of each other:

1. **sitectl on each server** (this project). It does every change
   safely and is the only component with root. It works on its own from
   the command line, and always will.
2. **A web control panel** with logins and roles. You, or someone given
   access to only their own site, can add sites, manage SFTP keys and
   change settings from a browser. The panel has no root. It asks
   sitectl through a narrow interface (`sitectl api`), and sitectl
   enforces a ceiling on what the panel may ask for.
3. **Central control of several servers.** One panel manages a fleet:
   web servers now, and later a Docker host, databases and mail. Each
   server runs sitectl, and something central drives them all securely.

Everything below is being built so these layers can be added without a
rewrite:
- every command declares an access level and scope
- changes are logged with who asked
- there is no local database to keep in sync
- output is moving to JSON

### Open question: how several servers are controlled

This hasn't been decided. Three ways are on the table:

| Option | How it works | For | Against |
|---|---|---|---|
| **A. A remote option in sitectl** | `sitectl --server web2 add example.com` runs `sitectl api` on web2 over SSH | Smallest step; every server is identical; nothing new to run | No fleet view; each workstation needs keys to every server |
| **B. Parent/child sitectl** | One server's sitectl is the "parent" and drives the others' | No extra program | Mixes two jobs in one tool; the parent server becomes the key to everything, and it's also hosting sites |
| **C. A separate `clusterctl`** | A controller (where the panel lives) keeps the server inventory and talks to each server's `sitectl api` | Clean split: sitectl stays single-server; the fleet logic (inventory, roles, rollouts across servers) has a home | A second project to build and secure |

Current leaning: **C, starting the way A works.** clusterctl begins as
"run `sitectl api` on server X over SSH", and grows an inventory and the
panel. Whichever option wins, the same groundwork applies:

- **`sitectl api` is the only way in from outside.** It speaks a
  versioned JSON request and response, and A, B and C all use it.
- **SSH as the transport:** the controller's key goes in each server's
  `authorized_keys` with `command="sudo /usr/local/sbin/sitectl api"`, so
  that key can only make API calls, never open a shell.
- **Each server keeps its own ceiling** in `/etc/sitectl/api.conf`, so a
  compromised controller still can't install modules or exceed what the
  server allows.
- **Server facts for an inventory:** a `sitectl info --json` command
  reporting version, modules, PHP versions and the web server.
- **The controller holds the keys to every server,** so it is the most
  sensitive part of the system. It should be its own small machine or
  VM, not one of the web servers.


## Where things stand (0.3.0)

- **Working and tested** (97 tests):
  - adding, redeploying and removing sites and subdomains, including
    several domains on one user
  - static and PHP sites, a private folder per site, AppArmor rules
  - certificates with a reachability check, staging and explained
    failures; existing certificates are reinstalled on redeploy and kept
    on remove
  - `list` (table and JSON)
  - the lock, the change log and the backups
  - test mode
  - settings and secrets per module
  - module packages: install, upgrade, uninstall, pack, new
  - SFTP as the first module
  - the command table with access levels
- **Upgrade path:** `install.sh` migrates from the original
  `add-new-site` script (`/etc/add-new-site` → `/etc/sitectl`) and from
  0.2. Files a new version drops are moved to the backups.
- **Module API 1** is defined. Only `sftp` uses it, so it can still
  change freely until a second module exists.


## Decisions made (don't revisit without a reason)

- **Bash**, plain and commented, maintained in vim. One library file per
  area.
- **Stateless:** the server is the source of truth. There's no database
  of sites.
- **Nothing is deleted;** everything goes to `/etc/sitectl/backups/`.
- **The username is the domain without dots and hyphens.** A clash is
  asked about (join the existing user, or take `<name>2`).
- **Subdomains join the main site's user by default,** in
  `/home/<user>/<subdomain>/`. `--separate-user` gives one its own.
- **The certificate check:** first DNS (any of the server's addresses),
  then a temporary hashed file fetched through the domain for
  Cloudflare. The file is created and removed as the site user. An
  existing certificate is always reinstalled offline before anything
  else, which fixed a lost-HTTPS-on-redeploy bug.
- **remove keeps the certificate** and pauses its renewal; only an
  expired one is deleted.
- **SFTP:** a chroot to the home folder, keys owned by root, connect by
  IP (Cloudflare doesn't pass SSH).
- **Modules:**
  - each has its own version and is installed from a package folder or
    `.tar.gz`
  - sitectl ships its defaults (built-in), and the newest version wins
  - no signing for now; checksums only detect damage
- **Providers inside modules** for multiple backends (see MODULES.md
  section 9).
- **Privileges:** sitectl is the only root component. Commands declare a
  level and scope; a future `sitectl api` behind one sudo rule serves
  the panel, with a per-caller ceiling (ARCHITECTURE.md, "Access levels
  and the future API"). A group with write access to configs was
  rejected because that's root in disguise.


## Other decisions from the build so far

- **Plain vhosts, no hosting-panel software.** The classic one user, one
  nginx vhost and one PHP pool per site. No WordPress-specific logic: a
  WordPress site is just a PHP site, and WordPress is installed by hand.
- **No credentials are saved anywhere they could be read back.** sitectl
  never generates or stores passwords for site users; SFTP is
  key-only.
- **The skeleton pages don't reveal** the PHP version or username.
- **Cloudflare:** an early version had special Cloudflare logic
  (DNS-01 and a strict DNS pre-check). It was removed as overbuilt. The
  only Cloudflare-specific code now detects its address ranges to
  explain failures, plus the file-fetch reachability check.
  - Behind the proxy, use SSL mode "Full" until the certificate exists.
- **Moving a site from another server:** `sitectl add` stages it (http
  only, no certificate request). Test it with a hosts-file line or the
  printed `curl` command, then switch DNS and run `add` again for the
  certificate.
- **Renewal** is certbot's own timer. sitectl adds no cron. Let's
  Encrypt no longer emails expiry warnings, so `list` shows expiry dates.
- **SSH dropping during SFTP use** turned out to be a router's intrusion
  prevention (a UniFi "ET SCAN Potential SSH Scan" signature) reacting
  to an SFTP client's parallel connections. The fix is one connection in
  the client, or an exception for the home IP. Recorded here because it
  looked like a server problem.
- **AppArmor:** Ubuntu 26.04 confines PHP-FPM in enforce mode, and its
  default profile blocks `/home`. Hence the per-user rules files.
- **Module naming:** a module is named for its job, not its provider:
  `dns` with Cloudflare and BIND providers, not a `cloudflare` module.
  Hosting a nameserver is a separate job (`nameserver`).
- **The panel doesn't run as `www-data`,** which is in every site's
  group.


## Next work, in order

1. **Web server as a provider; certificate rework.** The open questions
   are answered in [DESIGN-0.4.md](DESIGN-0.4.md): where ACME challenge
   files go, renewal reloads, migrating existing certificates, TLS
   settings, marker comments, and Apache's PHP. It also covers two bugs
   folded into this work: duplicate pools when a second PHP version is
   installed, and `open_basedir` missing web folders outside the home.
   - Don't hard-code nginx: nginx first, Apache next.
   - A core interface along the lines of `webserver_write_site`,
     `webserver_test`, `webserver_reload`, `webserver_read_site` and
     `webserver_disable_site`, with `lib/webservers/nginx.sh` and later
     `apache.sh`, chosen by a core setting.
   - sitectl writes the **whole** config itself, including the HTTPS
     server block and the redirect. certbot only obtains and renews
     (`certonly --webroot`, or DNS later), never edits configs.
     Redeploys become simpler and predictable.
   - `read_existing_site` (which reads `root`, `fastcgi_pass` and
     `server_name` out of nginx syntax) moves behind the provider.
     Consider writing the site's facts as marker comments in the config
     (`# sitectl: user=… type=… root=… www=…`) so reading back doesn't
     depend on server syntax.
   - Existing sites must keep working: the next redeploy rewrites their
     config in the new form.
2. **`sitectl api` and `/etc/sitectl/api.conf`,** when the panel work
   starts. JSON in and out, a ceiling per caller, `on_behalf_of` in the
   log. Every command will also need `--json` output (only `list` and
   `commands` have it now).
3. **dns module:**
   - providers `manual`, `cloudflare` (API token as a secret) and
     `rfc2136` (BIND or PowerDNS through `nsupdate` and TSIG)
   - the provider chosen per domain from its NS records
   - creates and updates A/AAAA records when sites are added, and can
     later issue certificates through DNS (certbot DNS plugins), which
     works behind Cloudflare and before the DNS switch
   - hosting BIND itself is a separate `nameserver` module
4. **Editing a site's settings without a full redeploy.** Today a
   change (www on or off, static or PHP, SSL) is made by running
   `sitectl add <domain>` again with the new options. The original wish
   list asked for direct edits, e.g.
   `sitectl site set example.com --www`. SFTP access and keys are already
   covered by `sitectl sftp`. Subdomains can be listed (in `list`),
   added and removed.
5. Later modules: `database` (MariaDB), `mail`, `docker` (apps on a
   separate VM), k8s and serverless.
6. **The web panel, then multi-server control** (see "Where this is
   going").
7. Smaller items noted:
   - `site-change` variants of add/remove for panel users
   - `--json` for `sftp status` and `modules`
   - signed packages, when installing from other people starts


## Project conventions

- In examples, use placeholder domains (`example.com`, `example.net`, and
  `exam-ple.com` for a hyphen), never real ones.
- Don't over-build: only what's asked for, and say so when something is
  being left out.
- Be very wary of deletion: no `rm -rf` or force flags. Back up, and if
  anything must go, `unlink` one checked path.
- Don't try to fix edge-case permissions on unusual custom paths: "that's
  on me".
- Secrets never on the command line or in logs.
- Tests only on throwaway machines.
- Explain the reason for design choices, briefly. Comments say why.
- Ask before big direction changes. Implement once agreed.


## Development notes

- **Working copy:** the project folder with `bin/`, `lib/`, `docs/`,
  `tests/`, `tools/`, `install.sh` and `uninstall.sh`. Run
  `bin/sitectl` directly to try changes; it uses the `lib/` next to it.
- **Lint everything together** (the libraries share globals):

  ```bash
  { sed -n '1,/^for library in/p' bin/sitectl | head -n -1
    for f in lib/*.sh lib/modules/*/module.sh; do tail -n +2 "$f"; done
    sed -n '/^CONFIG_DIR=/,$p' bin/sitectl; } > /tmp/all.sh
  shellcheck -s bash /tmp/all.sh lib/module-template/module.sh install.sh uninstall.sh tools/release.sh tests/run-tests.sh
  ```

- **Release:** bump `SITECTL_VERSION` in `bin/sitectl` (and a built-in
  module's `version` if it changed), update the README's version, run
  the tests, then `tools/release.sh`.
- **Container gotchas met so far:**
  - no systemd (the test shims cover it)
  - no IPv6 (nginx's `listen [::]` is only written when the server has
    IPv6)
  - no `column` command (`align_columns` uses awk)
  - a pip-installed `cryptography` that broke the system certbot (run
    the tests with `CERTBOT_REAL` pointing at a wrapper that sets
    `PYTHONPATH=/usr/lib/python3/dist-packages`). Where `/usr/bin/python3`
    isn't Ubuntu's own Python, the wrapper also has to name it:

    ```sh
    #!/bin/sh
    PYTHONPATH=/usr/lib/python3/dist-packages exec /usr/bin/python3.12 -s /usr/bin/certbot "$@"
    ```

  - no IPv6 at all, while Ubuntu's stock default site listens on
    `[::]:80`, so every `nginx -t` fails. Comment that line out in
    `/etc/nginx/sites-available/default` on the test machine (sitectl's
    own configs already leave IPv6 out there).
  - scripts losing their executable bit when files are uploaded through
    GitHub's web page. Keep the modes in git
    (`git add --chmod=+x <file>`) for `bin/sitectl`, the tests, their
    shims, `install.sh`, `uninstall.sh` and `tools/release.sh`.
  - a daemon started during a run kept the lock's file descriptor open
    (fixed: `run` and `systemctl` close fd 9)
- **Bash pitfalls already hit:**
  - a function called in `$( )` can't set globals for the caller (hence
    `MANIFEST_PROBLEM`, `PACKAGE_PROBLEM` and `UNPACKED_DIR`)
  - a bare `return` inside an exit trap returns the trapped status
  - `pipefail` with `grep -q` can fail the pipeline, so capture output
    first
  - `local -n` name clashes in `ask` (hence the `_ask_` prefixes)
