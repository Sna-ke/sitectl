# 0.4 design answers: web server providers and certificates

Answers to the questions raised before starting the 0.4 work (web server
as a provider, sitectl writing the full config, certbot only issuing).
Where an answer says "recommended", it's the default unless the project
owner decides otherwise.


## 1. Where ACME challenge files go

**A shared folder outside every home: `/var/lib/sitectl/acme`.** The
roadmap said `certonly --webroot` without saying where; pointing it at
each site's web root would make certbot (root) write inside
`/home/<user>`, which breaks the rule.

- `/var/lib/sitectl/acme/` is root-owned, 755, and readable by
  `www-data`. certbot runs `certonly --webroot -w /var/lib/sitectl/acme`.
- Every vhost gets the same location, in **both** the port 80 and the
  port 443 server blocks, ahead of any redirect:

  ```nginx
  location ^~ /.well-known/acme-challenge/ {
      root /var/lib/sitectl/acme;
      default_type text/plain;
      try_files $uri =404;
  }
  ```

  It's in both blocks because Cloudflare's "Always Use HTTPS" (or an
  http→https redirect) sends Let's Encrypt to https. Let's Encrypt follows
  that redirect, and the https block must still answer.
- **The reachability check moves there too.** Its test file goes in
  `/var/lib/sitectl/acme/.well-known/sitectl-check/` (a matching
  `location ^~ /.well-known/sitectl-check/` with the same root). It's
  written by root outside any home, so the `runuser` dance for the test
  file goes away. The file is still removed after the check.
- The same folder works for Apache with an `Alias` (see 6).


## 2. Reloading the web server on renewal

**A deploy hook file: `/etc/letsencrypt/renewal-hooks/deploy/sitectl`**,
installed and kept up to date by sitectl.

- It runs after every successful renewal of any certificate, including
  ones made before sitectl or by hand, and includes migrated ones (see 3).
  There's one file to change if the web server changes. A `--deploy-hook`
  on each certificate instead gets stored in every renewal file and would
  need rewriting for every certificate.
- It tests the config and then reloads, and does nothing else. For nginx:
  `nginx -t -q && systemctl reload nginx`. It's written for the server's
  one web server (see 6). If the test fails, it exits non-zero, which
  certbot logs, and the running server keeps the old certificate rather
  than going down.
- On first issue, sitectl reloads the server itself; it doesn't rely on
  the hook.


## 3. Moving existing certificates over

**Migrate on redeploy; don't wait for renewal.** A renewal file with
`installer = nginx` makes certbot **edit the vhost at every renewal**,
and that config is now sitectl's. Leaving the files as they are means
certbot keeps rewriting configs sitectl owns.

- On redeploy, if `/etc/letsencrypt/renewal/<domain>.conf` still says
  `authenticator = nginx` or has an `installer` line, run:

  ```
  certbot reconfigure --cert-name <domain> --webroot -w /var/lib/sitectl/acme
  ```

  This is the supported way (certbot 2.3+; Ubuntu 24.04+ has it). Don't
  hand-edit renewal files. `reconfigure` does a test renewal against
  Let's Encrypt's staging server, so it needs the domain to reach this
  server.
- If it fails (the domain isn't reachable yet, or certbot is too old),
  leave the file as it is, finish the redeploy, and say so in the
  summary: the certificate still renews the old way, and the next
  redeploy tries again.
- The certificate itself isn't touched or re-issued; only how it renews
  changes.
- `sitectl list` could flag certificates still on the old method later.
  Not needed for 0.4.


## 4. TLS settings

**sitectl writes its own, in one shared file it owns**, included by
every vhost: for nginx, `/etc/nginx/snippets/sitectl-tls.conf`.

- Don't keep including certbot's `options-ssl-nginx.conf` and
  `ssl-dhparams.pem`. certbot owns and updates them, they only exist when
  the nginx plugin is installed, and there's nothing equivalent for
  Apache. One file of sitectl's own also makes it easy to raise the
  settings for every site at once.
- Use Mozilla's "intermediate" profile: TLS 1.2 and 1.3, ECDHE ciphers
  only (so no dhparam file is needed), and sensible session settings
  (cache on, tickets off).
- **Don't turn on OCSP stapling.** Let's Encrypt certificates no longer
  carry OCSP URLs, so nginx would only log warnings.
- **No HSTS by default.** Once a browser sees HSTS it refuses http for
  that name for the whole max-age. That fights the workflow sitectl is
  built around:
  - sites staged on http while they move servers
  - subdomains that may not have certificates yet, if `includeSubDomains`
    is ever used
  - Cloudflare SSL mode changes during a move

  If wanted later: a per-site opt-in (`--hsts`), without
  `includeSubDomains`, starting with a short max-age, and never preload.


## 5. Marker comments vs parsing

**Markers are the source of truth when present; parsing stays only as
the reader for older configs.**

- New configs carry one line, e.g.
  `# sitectl: user=examplecom type=php root=/home/examplecom/public_html www=yes`.
  `read_existing_site` uses it when present. Apache configs only ever
  have markers.
- Configs from before 0.4 (marked "managed by sitectl" or "created by
  add-new-site" but with no facts line) are read by the current parser,
  which moves inside the nginx provider as a legacy reader. The next
  redeploy rewrites them in the new form.
- Validate marker values exactly as user input is validated (username
  pattern, path rules), even though only root can write there.
- **A hand edit the markers don't reflect** (say someone changes `root`
  by hand): the markers win, but the nginx provider compares the parsed
  `root` with the marker and warns about the difference. This keeps the
  "stateless, a hand edit is never silently lost" spirit without parsing
  being the source again. Document it: change a site with sitectl, or
  edit the marker line too.


## 6. One web server per server, and Apache's PHP

**One per server.** Both want ports 80 and 443; mixing them needs a
reverse proxy in front, which isn't worth it for this.

- A core setting, `web_server = nginx | apache`. Changing it on a server
  with sites is a migration (rewrite every site, switch services), so
  make it a deliberate command later, not a plain `config set`. For 0.4,
  only nginx exists.
- **Apache uses the same PHP-FPM pools**: the event MPM, `mod_proxy_fcgi`
  to `/run/php/<user>.sock`, and the same per-user pools, AppArmor rules
  and `open_basedir`. **Never `mod_php`**: it runs every site as
  `www-data` (no isolation between sites) and needs the prefork MPM.
- An open question for the Apache work, not 0.4: `AllowOverride`.
  WordPress uses `.htaccess` for permalinks, but `AllowOverride All` lets
  a site change its own server behaviour. Decide when Apache is built.


## 7. Two PHP versions and duplicate pools (a real bug)

Not considered before; it's a bug today. Installing 8.4 next to 8.3
makes the next redeploy write a second pool under 8.4 with the same
socket, and the two FPMs fight over it. `remove` only looks under the
newest version.

- **Find the user's pool where it actually is:**
  `/etc/php/*/fpm/pool.d/<user>.conf`. A redeploy keeps the version the
  pool is on. A new site gets the newest version, as now.
- **Changing a site's PHP version is explicit** (e.g. a later
  `--php-version 8.4`): back up the old pool, write the new one, reload
  both FPMs. Because the pool is per user, this moves every PHP site on
  that user, and the confirmation should say so.
- `retire_php_pool` and `remove` check every version. If a user has
  pools under more than one version (servers already hit by this), warn,
  keep the newest, and back up the others on the next redeploy.
- Fold it into the 0.4 work: it touches the same code (reading a site
  back, writing its configs).


## 8. `open_basedir` for web folders outside the home (a real bug)

Not the intent. "That's on me" was about **permissions** on custom
paths: who owns `/srv/...` and the folders above it. It doesn't cover
sitectl's own generated config being incomplete.

- AppArmor rules already include an outside web root, but `open_basedir`
  is only `$HOME_DIR/`, so PHP there fails.
- The pool's comment says to add other folders by hand, but every
  redeploy rewrites the pool and drops the edit.
- Fix: build `open_basedir` from the same list as the AppArmor rules (the
  home, plus every outside PHP web root of that user's sites), and remove
  the hand-edit comment.


## Workflow and testing (the project owner's decisions)

Both decided: commits and pull requests in the GitHub repository, and
tests in the session's disposable container. ROADMAP.md has the details.

- **Commits instead of tarballs.** Recommended: work happens in the
  GitHub repo, one branch and pull request per piece of work, so each
  change is reviewed before it's merged (this matches "ask before big
  direction changes"). That needs push access for the session.
  Otherwise, hand over a patch to commit. Update ROADMAP.md's "how to
  start a session" section once decided.
- **Tests in the cloud workspace.** An isolated, disposable container
  fits "throwaway machine"; the 0.3.0 suite was run in one. Expect no
  systemd (the shims handle it), and possibly a certbot broken by a
  pip-installed `cryptography` (run with `CERTBOT_REAL` pointing at a
  wrapper that sets `PYTHONPATH=/usr/lib/python3/dist-packages`). Never
  on a real server.
