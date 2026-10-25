#!/usr/bin/env bash
#
# run-tests.sh: sitectl's regression tests.
#
# ONLY run this on a throwaway Ubuntu VM or container, never on a real
# server: it creates users, sites, SSH settings and fake certificates.
#
#   sudo SITECTL_TEST_ON_THROWAWAY_MACHINE=yes tests/run-tests.sh
#
# Needs: nginx, php-fpm, curl, openssl, certbot with its nginx plugin
# (set CERTBOT_REAL if it isn't /usr/bin/certbot), and optionally
# openssh-server + openssh-client for the SFTP tests. Works with or
# without systemd: systemctl is replaced by a stand-in during the tests.

set -uo pipefail

if [[ "${SITECTL_TEST_ON_THROWAWAY_MACHINE:-}" != "yes" ]]; then
  echo "Refusing to run: these tests change the machine (users, sites, SSH)." >&2
  echo "On a throwaway VM/container, run:" >&2
  echo "  sudo SITECTL_TEST_ON_THROWAWAY_MACHINE=yes $0" >&2
  exit 1
fi
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SITECTL="$HERE/../bin/sitectl"
export PATH="$HERE/shims:$PATH"
WORK=/tmp/sitectl-test
mkdir -p "$WORK"

# Unique names per run, so the tests can be rerun on the same machine.
RUN=$(tr -dc '[:lower:]' < /dev/urandom | head -c 5)
MAIN="main$RUN.test"
MAINUSER="main${RUN}test"
OTHER="other$RUN.test"
MYIP=$(ip -o addr show scope global | awk '{ split($4, a, "/"); print a[1] }' | head -n 1)

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "  ok    $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL  $1"; }
check() {          # check "description" command...
  local what="$1"; shift
  if "$@" > /dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
# (Output is captured first, then searched: piping straight into grep -q
# can make the command fail as grep stops reading early.)
output_has() {     # output_has "description" "pattern" command...
  local what="$1" pattern="$2" out; shift 2
  out=$("$@" 2>&1)
  if grep -qE -- "$pattern" <<< "$out"; then pass "$what"
  else fail "$what"; printf '%s\n' "$out" | tail -n 5 | sed 's/^/          | /'; fi
}
page_has() {       # page_has "description" host path pattern
  local out
  out=$(curl -s -H "Host: $2" "http://127.0.0.1$3")
  if grep -qE -- "$4" <<< "$out"; then pass "$1"; else fail "$1"; fi
}
status_is() {      # status_is "description" host path code
  local code
  code=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' -H "Host: $2" "http://127.0.0.1$3")
  if [[ "$code" == "$4" ]]; then pass "$1"; else fail "$1 (got $code)"; fi
}
fingerprint() {
  { getent passwd; getent group
    find /etc/nginx /etc/php /etc/sitectl /etc/ssh /etc/letsencrypt /home \
         -printf '%p %s %T@ %u %m\n' 2> /dev/null; } | sort | sha256sum
}
sc() { "$SITECTL" "$@" < /dev/null; }

echo "== Setup"
pgrep -x nginx > /dev/null || nginx
pgrep -f php-fpm > /dev/null || "$(find /usr/sbin -name 'php-fpm*' | sort | tail -n 1)" -D
# Known settings for the tests; any existing settings file is put back at
# the end.
mkdir -p /etc/sitectl
if [[ -f /etc/sitectl/sitectl.conf ]]; then
  cp -p /etc/sitectl/sitectl.conf "$WORK/sitectl.conf.saved"
fi
cat > /etc/sitectl/sitectl.conf <<'EOF'
CERTBOT_EMAIL=test@example.com
DEFAULT_PATH=public_html
DEFAULT_SITE_TYPE=php
INCLUDE_WWW=yes
GET_CERTIFICATE=no
EOF
mkdir -p /etc/sitectl/skel/php /etc/sitectl/skel/static
[[ -f /etc/sitectl/skel/php/index.php ]] ||
  printf '<h1>Hello from {{DOMAIN}}</h1>\n<p><?= "PHP is working." ?></p>\n' > /etc/sitectl/skel/php/index.php
[[ -f /etc/sitectl/skel/static/index.html ]] ||
  printf '<h1>Hello from {{DOMAIN}}</h1>\n' > /etc/sitectl/skel/static/index.html
cp /etc/hosts "$WORK/hosts.saved"
: > "$WORK/certbot-calls.log"
echo "  run id: $RUN   main site: $MAIN"

echo "== Test mode changes nothing"
before=$(fingerprint)
sc add "$MAIN" -t > /dev/null 2>&1
sc add-subdomain "$MAIN" demo -t > /dev/null 2>&1
check "add / add-subdomain with -t leave the machine unchanged" test "$before" = "$(fingerprint)"

echo "== Adding a PHP site"
output_has "add reports success" "Done: $MAIN" sc add "$MAIN" --no-ssl
check "site user has no login shell" bash -c "getent passwd $MAINUSER | grep -q nologin"
check "home is owned by root, mode 750" bash -c "[[ \$(stat -c '%U %a' /home/$MAINUSER) == 'root 750' ]]"
check "private folder exists, mode 700" bash -c "[[ \$(stat -c '%U %a' /home/$MAINUSER/private) == '$MAINUSER 700' ]]"
check "nginx config is marked as managed" grep -q "managed by sitectl" "/etc/nginx/sites-available/$MAIN"
page_has "skeleton page is served, with the domain filled in" "$MAIN" / "Hello from $MAIN"
page_has "PHP runs" "$MAIN" / "PHP is working"
check "PHP runs as the site user" bash -c "curl -s -H 'Host: $MAIN' http://127.0.0.1/ > /dev/null; pgrep -u $MAINUSER php-fpm"

echo "== Private folder"
printf '<?php return "secret";\n' > "/home/$MAINUSER/private/config.php"
chown "$MAINUSER:" "/home/$MAINUSER/private/config.php"
printf '<?php echo "len=" . strlen(require __DIR__ . "/../private/config.php");\n' > "/home/$MAINUSER/public_html/usecfg.php"
chown "$MAINUSER:" "/home/$MAINUSER/public_html/usecfg.php"
page_has "PHP can read private/" "$MAIN" /usecfg.php "len=6"
status_is "private/ isn't served (direct)" "$MAIN" /private/config.php 404
status_is "private/ isn't served (../ trick)" "$MAIN" /../private/config.php 400
check "nginx's user can't read private/" bash -c "! runuser -u www-data -- cat /home/$MAINUSER/private/config.php"

echo "== Subdomains and other domains on the same user"
output_has "add-subdomain joins the main user" "Adding it to $MAINUSER" sc add-subdomain "$MAIN" demo --no-ssl
check "subdomain folder is next to public_html" test -d "/home/$MAINUSER/demo.$MAIN"
page_has "subdomain is served" "demo.$MAIN" / "Hello from demo.$MAIN"
output_has "add-subdomain refuses an unknown main domain" "isn't set up on this server" sc add-subdomain "nope$RUN.test" demo
output_has "add-subdomain refuses www" "www is part of the main site" sc add-subdomain "$MAIN" www
output_has "--user adds another domain to that user" "Adding $OTHER to existing user" sc add "$OTHER" --user "$MAINUSER" --no-ssl
check "the other domain gets its own folder" test -d "/home/$MAINUSER/$OTHER"

echo "== Unsafe paths are refused"
output_has "path with ; is refused" "isn't a usable path" sc add "bad$RUN.test" --path 'www;x' -t
output_has "system folder is refused" "system folder" sc add "bad$RUN.test" --path /etc -t
output_has "private as web folder is refused" "kept out of public view" sc add-subdomain "$MAIN" x --path private -t

echo "== Redeploy, and switching PHP <-> static"
echo "keep me" > "/home/$MAINUSER/public_html/keep.txt"
output_has "redeploy succeeds" "Redeployed: $MAIN" sc add "$MAIN" --yes --no-ssl
check "redeploy keeps the site's files" grep -q "keep me" "/home/$MAINUSER/public_html/keep.txt"
sc add "$OTHER" --static --yes --no-ssl > /dev/null 2>&1
status_is "a static site never shows .php source" "$OTHER" /index.php 404

echo "== Certificates"
printf '%s %s www.%s\n' "$MYIP" "$MAIN" "$MAIN" >> /etc/hosts
mkdir -p "/etc/letsencrypt/live/$MAIN"
openssl req -x509 -newkey rsa:2048 -nodes -days 80 -subj "/CN=$MAIN" \
  -addext "subjectAltName=DNS:$MAIN,DNS:www.$MAIN" \
  -keyout "/etc/letsencrypt/live/$MAIN/privkey.pem" -out "/etc/letsencrypt/live/$MAIN/cert.pem" 2> /dev/null
cp "/etc/letsencrypt/live/$MAIN/cert.pem" "/etc/letsencrypt/live/$MAIN/fullchain.pem"
: > "$WORK/certbot-calls.log"
sc add "$MAIN" --ssl --yes > "$WORK/redeploy-cert.log" 2>&1
check "redeploy reinstalls an existing certificate" grep -q "listen 443" "/etc/nginx/sites-available/$MAIN"
check "...without asking Let's Encrypt for a new one" bash -c "! grep -qv '^install$' $WORK/certbot-calls.log"
printf '192.0.2.99 staged%s.test www.staged%s.test\n' "$RUN" "$RUN" >> /etc/hosts
: > "$WORK/certbot-calls.log"
# Certificates on by default (not forced with --ssl), as for a real site.
sed -i 's/^GET_CERTIFICATE=no/GET_CERTIFICATE=yes/' /etc/sitectl/sitectl.conf
output_has "a domain pointing elsewhere is staged" "Staged: no certificate requested" sc add "staged$RUN.test"
sed -i 's/^GET_CERTIFICATE=yes/GET_CERTIFICATE=no/' /etc/sitectl/sitectl.conf
check "...and no certificate request was made" bash -c "! grep -q -- '--nginx' $WORK/certbot-calls.log"
check "...and the check's temporary file was removed" bash -c "[[ ! -e /home/staged${RUN}test/public_html/.well-known ]]"

echo "== Remove"
output_has "remove-subdomain keeps the shared PHP pool" "keep the PHP pool" sc remove-subdomain "$MAIN" demo --yes
output_has "remove keeps the certificate and pauses renewal" "keep the certificate" sc remove "$MAIN" --yes
check "the certificate files are still there" test -f "/etc/letsencrypt/live/$MAIN/fullchain.pem"
check "the site's files are still there" test -f "/home/$MAINUSER/public_html/keep.txt"

echo "== Lock and change log"
(exec 9> /run/sitectl.lock; flock 9; sleep 5) &
sleep 1
output_has "a second change is refused while one is running" "another sitectl change is running" sc add "lock$RUN.test" --no-ssl
wait
check "changes are logged" grep -q "sitectl add $OTHER" /var/log/sitectl.log

echo "== list"
check "list --json is valid JSON" bash -c "\"$SITECTL\" list --json | python3 -c 'import json,sys; json.load(sys.stdin)'"
output_has "list shows a site" "$OTHER" "$SITECTL" list

echo "== Command table and access levels"
check "commands --json is valid JSON" bash -c "\"$SITECTL\" commands --json | python3 -c 'import json,sys; json.load(sys.stdin)'"
output_has "every command has a level" "sftp.add-key +site-change +site" "$SITECTL" commands
output_has "a change needs root" "needs sudo" runuser -u nobody -- "$SITECTL" sftp disable "$OTHER"
output_has "a read doesn't" "SFTP (on|off)" runuser -u nobody -- "$SITECTL" sftp status "$OTHER"
output_has "installing modules needs root" "needs sudo" runuser -u nobody -- "$SITECTL" modules install x.tar.gz
output_has "arguments are checked against the usage" "usage: sitectl sftp add-key <domain> <key>" "$SITECTL" sftp add-key "$OTHER"
output_has "a site command's domain is checked first" "doesn't look like a domain" "$SITECTL" sftp disable 'x;y'

echo "== Module packages"
MOD="t$RUN"
cd "$WORK" || exit 1
output_has "modules new makes a package from the template" "Made ./$MOD.pkg" sc modules new "$MOD"
output_has "pack writes CHECKSUMS and an archive" "Made .*$MOD-1.0.0.tar.gz" sc modules pack "$MOD.pkg"
check "...and the archive's folder is named after the module" bash -c "tar -tzf $MOD-1.0.0.tar.gz | grep -qx '$MOD/module.sh'"
output_has "install asks before running anything as root" "Modules run as root" sc modules install "$MOD-1.0.0.tar.gz" --yes
check "...and leaves no temporary folder behind" bash -c "! ls -d /tmp/sitectl-module.* 2> /dev/null"
output_has "an installed module is listed" "$MOD +1.0.0 +disabled +installed" "$SITECTL" modules
check "installed files are root's and not writable by others" bash -c \
  "[[ -z \$(find /var/lib/sitectl/modules/$MOD ! -user root -o -perm /022) ]]"
cp -R "$MOD.pkg" "bad$RUN.pkg"; echo '# changed' >> "bad$RUN.pkg/module.sh"
output_has "a changed file is refused" "doesn't match CHECKSUMS" sc modules install "bad$RUN.pkg" --yes
sc modules pack "bad$RUN.pkg" > /dev/null 2>&1; echo x > "bad$RUN.pkg/extra.txt"
output_has "a file missing from CHECKSUMS is refused" "isn't listed in CHECKSUMS" sc modules install "bad$RUN.pkg" --yes
unlink "bad$RUN.pkg/extra.txt"; ln -s /etc/passwd "bad$RUN.pkg/link"
output_has "a link in a package is refused" "links or special files" sc modules install "bad$RUN.pkg" --yes
unlink "bad$RUN.pkg/link"; sed -i 's/^api=1/api=99/' "bad$RUN.pkg/module.conf"
output_has "a module for another API is refused" "module API '99'" sc modules install "bad$RUN.pkg" --yes
sc modules install "$MOD-1.0.0.tar.gz" > /dev/null 2>&1      # no --yes, no terminal: cancelled
output_has "a cancelled change is logged as failed" "failed .*modules install $MOD-1.0.0.tar.gz" tail -n 1 /var/log/sitectl.log
sed -i 's/^version=.*/version=1.1.0/' "$MOD.pkg/module.conf"
sc modules pack "$MOD.pkg" > /dev/null 2>&1
output_has "a newer version is an upgrade" "upgrade from 1.0.0" sc modules install "$MOD-1.1.0.tar.gz" --yes
check "...and the old version is kept in the backups" bash -c "ls -d /etc/sitectl/backups/*-module-$MOD/$MOD"
output_has "an older version is flagged as a downgrade" "DOWNGRADE from 1.1.0" sc modules install "$MOD-1.0.0.tar.gz" -t
cp -R "$MOD.pkg" "decl$RUN.pkg"
sed -i 's/^hello|read|site|/hello|superuser|site|/' "decl$RUN.pkg/module.sh"
sed -i "s/^name=.*/name=d$RUN/; s/^version=.*/version=1.0.0/" "decl$RUN.pkg/module.conf"
sed -i "s/module_${MOD}_/module_d${RUN}_/g" "decl$RUN.pkg/module.sh"
sc modules pack "decl$RUN.pkg" > /dev/null 2>&1
sc modules install "d$RUN-1.0.0.tar.gz" --yes > /dev/null 2>&1
output_has "a module with a bad command declaration isn't loaded" "unknown level 'superuser'" "$SITECTL" modules
sc modules uninstall "d$RUN" --yes > /dev/null 2>&1
cd "$HERE" || exit 1

echo "== Settings, hooks, options and commands"
output_has "core settings can be read" "^test@example.com$" "$SITECTL" config get core.certbot_email
output_has "bad values are refused" "use one of: php static" sc config set core.default_site_type maybe
output_has "enabling needs required settings first" "needs these settings first: api_token" sc modules enable "$MOD"
output_has "a secret on the command line is refused" "set-secret" sc config set "$MOD.api_token" abc
echo "TOPSECRET$RUN" | "$SITECTL" config set-secret "$MOD.api_token" > /dev/null 2>&1
check "the secret is stored root-only (600)" bash -c "[[ \$(stat -c '%a %U' /etc/sitectl/secrets/$MOD.conf) == '600 root' ]]"
output_has "show doesn't reveal the secret" "api_token +\(secret: set\)" "$SITECTL" config show "$MOD"
check "the secret never reaches the log" bash -c "! grep -q TOPSECRET$RUN /var/log/sitectl.log"
check "...or the output of show" bash -c "! \"$SITECTL\" config show | grep -q TOPSECRET$RUN"
output_has "without sudo, show doesn't guess" "run with sudo" runuser -u nobody -- "$SITECTL" config show "$MOD"
sc config set "$MOD.greeting" "Hi there" > /dev/null 2>&1
output_has "enabling runs the module's check" "Settings look fine" sc modules enable "$MOD"
output_has "a module's option reaches its hooks" "Note: from the test" sc add "hook$RUN.test" --no-ssl --"$MOD"-note "from the test"
output_has "hooks run when a site is added" "Hi there, hook$RUN.test" sc add "hook$RUN.test" --no-ssl --yes
output_has "a module adds a list column" "${MOD^^}" "$SITECTL" list
output_has "a module adds a command" "Hi there, hook$RUN.test!" "$SITECTL" "$MOD" hello "hook$RUN.test"
output_has "hooks run when a site is removed" "Goodbye, hook$RUN.test" sc remove "hook$RUN.test" --yes
sc modules disable "$MOD" > /dev/null 2>&1
output_has "a disabled module's option is unknown" "unknown option: --$MOD-note" sc add "x$RUN.test" --"$MOD"-note hi -t
output_has "a disabled module's command is refused" "is disabled" "$SITECTL" "$MOD" hello "$OTHER"
output_has "disabling keeps the settings" "^Hi there$" "$SITECTL" config get "$MOD.greeting"
chmod o+w "/var/lib/sitectl/modules/$MOD/module.sh"
output_has "a module others can write to is skipped" "must be owned by root" "$SITECTL" modules
chmod o-w "/var/lib/sitectl/modules/$MOD/module.sh"
output_has "uninstall keeps the files in the backups" "the files are in /etc/sitectl/backups" sc modules uninstall "$MOD" --yes
check "...and the module is gone" bash -c "! \"$SITECTL\" modules | grep -q '^$MOD '"

echo "== SFTP"
if command -v sshd > /dev/null && command -v sftp > /dev/null; then
  ssh-keygen -q -t ed25519 -N '' -f "$WORK/key$RUN" -C test
  sc add "sftp$RUN.test" --sftp-key "$WORK/key$RUN.pub" --no-ssl > /dev/null 2>&1
  ssh-keygen -A > /dev/null; mkdir -p /run/sshd
  /usr/sbin/sshd -p 2299 -o ListenAddress=127.0.0.1 -o PidFile=/run/sshd-sitectl-test.pid
  sleep 1
  SFTP=(sftp -q -o IdentitiesOnly=yes -i "$WORK/key$RUN" -P 2299 -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null -o BatchMode=yes "sftp${RUN}test@127.0.0.1")
  output_has "SFTP login lands in the jail" "public_html" bash -c "echo ls | ${SFTP[*]}"
  output_has "SFTP can't leave the jail" "not found" bash -c "echo 'ls /etc' | ${SFTP[*]}"
  output_has "shell login is refused" "sftp connections only" \
    ssh -i "$WORK/key$RUN" -p 2299 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes "sftp${RUN}test@127.0.0.1" id
  SITE="sftp$RUN.test"
  output_has "sftp status lists the key" "SHA256:.* test" "$SITECTL" sftp status "$SITE"
  ssh-keygen -q -t ed25519 -N '' -f "$WORK/key2$RUN" -C second
  output_has "add-key adds a key" "key added" sc sftp add-key "$SITE" "$WORK/key2$RUN.pub" --yes
  output_has "...and the same key twice is noticed" "already allowed" sc sftp add-key "$SITE" "$WORK/key2$RUN.pub" --yes
  output_has "a second key can log in" "public_html" bash -c "echo ls | ${SFTP[*]/key$RUN/key2$RUN}"
  output_has "remove-key removes a key by comment" "Removed 1 key" sc sftp remove-key "$SITE" test --yes
  check "...so it can't log in" bash -c "! echo ls | ${SFTP[*]}"
  output_has "remove-key with no match changes nothing" "no key .* matches" sc sftp remove-key "$SITE" nosuch --yes
  output_has "disable takes the user out of SFTP" "SFTP disabled" sc sftp disable "$SITE" --yes
  check "...and out of the sftponly group" bash -c "! id -nG sftp${RUN}test | grep -qw sftponly"
  output_has "enable turns it back on" "SFTP on" bash -c "\"$SITECTL\" sftp enable $SITE --yes < /dev/null > /dev/null 2>&1; \"$SITECTL\" sftp status $SITE"
  output_has "-t before the command works too" "\[test\]" sc -t sftp add-key "$SITE" "$WORK/key$RUN.pub"
  kill "$(cat /run/sshd-sitectl-test.pid)" 2> /dev/null
else
  echo "  skip  SFTP tests (openssh-server/client not installed)"
fi

cp "$WORK/hosts.saved" /etc/hosts
if [[ -f "$WORK/sitectl.conf.saved" ]]; then
  cp -p "$WORK/sitectl.conf.saved" /etc/sitectl/sitectl.conf
fi
echo
echo "== $PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
