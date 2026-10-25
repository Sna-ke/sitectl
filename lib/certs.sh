# shellcheck shell=bash
#
# sitectl library: Let's Encrypt certificates, staging, and diagnosing failures.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.

# -----------------------------------------------------------------------------
#  Step 7: Get a Let's Encrypt certificate
# -----------------------------------------------------------------------------

# What happened with the certificate: ok, staged, failed or off.
CERT_STATE="off"

# Build the certbot command for this site in CERTBOT_COMMAND.
set_certbot_command() {
  # certbot takes each hostname as -d <name>.
  local domains=(-d "$DOMAIN")
  if [[ "$ADD_WWW" == "yes" ]]; then
    domains+=(-d "www.$DOMAIN")
  fi

  # --nginx: prove ownership over HTTP, then add HTTPS to the nginx config.
  # --cert-name keeps one certificate per domain, named after it, so a
  # redeploy that adds or drops www updates that certificate (instead of
  # failing, or making a second "example.com-0001" one), and remove
  # finds it by name.
  # --redirect sends all http:// visitors to https://.
  # --keep-until-expiring reuses a valid existing certificate (e.g. on a
  # redeploy) instead of requesting a new one.
  CERTBOT_COMMAND=(certbot --nginx --cert-name "$DOMAIN" "${domains[@]}"
                   --non-interactive --agree-tos -m "$CERTBOT_EMAIL"
                   --keep-until-expiring --redirect)
}

# --- Is the domain reaching this server yet? -------------------------------
#
# Let's Encrypt checks a domain by fetching a file from it over HTTP, so
# there's no point asking for a certificate until each name reaches this
# server. Two checks, cheapest first:
#
#   1. DNS: if every address the name resolves to is one of this server's,
#      it reaches us.
#   2. A test file: otherwise (e.g. behind Cloudflare's proxy, which hides
#      the server's address), put a temporary file with a random hashed
#      value in the web folder, fetch it through the domain, and compare.
#      This is the same trip Let's Encrypt's request makes. The file is
#      removed afterwards.

# Returns success if every address $1 resolves to belongs to this server.
name_resolves_to_this_server() {
  local name="$1" addresses ip my_ips
  my_ips=$(ip -o addr show scope global | awk '{ split($4, a, "/"); print a[1] }')
  addresses=$(getent ahosts "$name" 2> /dev/null | awk '{ print $1 }' | sort -u || true)
  [[ -n "$addresses" ]] || return 1
  for ip in $addresses; do
    grep -qxF "$ip" <<< "$my_ips" || return 1
  done
}

# Check which names reach this server, using a temporary test file.
# Sets NOT_REACHING to the names that don't. Returns failure (and leaves
# NOT_REACHING empty) if the test file couldn't be created, so the
# caller can fall back to just trying.
#
# The file is created and removed as the site user, never as root, since
# the web folder belongs to the site. Only the folders this check created
# are removed again, and only if they're empty.
check_names_with_test_file() {
  NOT_REACHING=()

  local check_dir="$WEB_ROOT/.well-known/sitectl-check"
  local file_name value file created_dirs=() dir name answer

  file_name="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n').txt"
  value=$(head -c 32 /dev/urandom | sha256sum | awk '{ print $1 }')
  file="$check_dir/$file_name"

  # Note which folders don't exist yet, so only those get tidied up.
  for dir in "$WEB_ROOT/.well-known" "$check_dir"; do
    [[ -d "$dir" ]] || created_dirs+=("$dir")
  done

  # shellcheck disable=SC2016  # $1-$3 are expanded by the inner sh
  if ! runuser -u "$SITE_USER" -- sh -c 'umask 022 && mkdir -p "$1" && printf "%s" "$2" > "$3"' \
         sh "$check_dir" "$value" "$file" 2> /dev/null; then
    return 1
  fi

  for name in $SERVER_NAMES; do
    if name_resolves_to_this_server "$name"; then
      continue
    fi
    answer=$(curl -sL --connect-timeout 5 --max-time 10 \
               "http://$name/.well-known/sitectl-check/$file_name" 2> /dev/null || true)
    if [[ "$answer" != "$value" ]]; then
      NOT_REACHING+=("$name")
    fi
  done

  # Clean up: the file, then any folders this check created (innermost
  # first), but only if they're empty.
  runuser -u "$SITE_USER" -- unlink "$file" 2> /dev/null || true
  local i
  for (( i = ${#created_dirs[@]} - 1; i >= 0; i-- )); do
    runuser -u "$SITE_USER" -- rmdir "${created_dirs[$i]}" 2> /dev/null || true
  done
}

# Fill NOT_REACHING with the names that don't reach this server yet.
find_names_not_reaching() {
  NOT_REACHING=()
  local name all_by_dns="yes"

  for name in $SERVER_NAMES; do
    name_resolves_to_this_server "$name" || all_by_dns="no"
  done
  if [[ "$all_by_dns" == "yes" ]]; then
    return
  fi

  if ! command -v curl > /dev/null || ! check_names_with_test_file; then
    warn "couldn't check whether $SERVER_NAMES reach this server; trying anyway"
    NOT_REACHING=()
  fi
}

# --- Existing certificates --------------------------------------------------

EXISTING_CERT_DIR=""

# Returns success if Let's Encrypt already has a certificate for this
# domain (needs root to see).
existing_certificate() {
  EXISTING_CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
  [[ -f "$EXISTING_CERT_DIR/fullchain.pem" && -f "$EXISTING_CERT_DIR/privkey.pem" ]]
}

# Returns success if the existing certificate covers every name and has
# at least 30 days left, so no new one is needed.
existing_certificate_is_enough() {
  local cert="$EXISTING_CERT_DIR/cert.pem" names name
  [[ -f "$cert" ]] || cert="$EXISTING_CERT_DIR/fullchain.pem"

  openssl x509 -in "$cert" -noout -checkend $(( 30 * 24 * 3600 )) > /dev/null 2>&1 || return 1

  names=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2> /dev/null \
            | grep -o 'DNS:[^,[:space:]]*' | cut -d: -f2)
  for name in $SERVER_NAMES; do
    grep -qxF "$name" <<< "$names" || return 1
  done
}

# Returns success if the existing certificate has already expired.
certificate_has_expired() {
  local cert="/etc/letsencrypt/live/$DOMAIN/cert.pem"
  [[ -f "$cert" ]] || cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  ! openssl x509 -in "$cert" -noout -checkend 0 > /dev/null 2>&1
}

# certbot renews every certificate with a file in /etc/letsencrypt/renewal
# ending in .conf. Renaming it pauses renewal for a removed site (there's
# no site to answer Let's Encrypt's check); renaming it back resumes it.
RENEWAL_DIR="/etc/letsencrypt/renewal"
PAUSED_SUFFIX=".paused-by-sitectl"

pause_certificate_renewal() {
  local conf="$RENEWAL_DIR/$DOMAIN.conf"
  if [[ -f "$conf" ]]; then
    run mv "$conf" "$conf$PAUSED_SUFFIX"
  fi
}

resume_certificate_renewal() {
  local conf="$RENEWAL_DIR/$DOMAIN.conf"
  if [[ -f "$conf$PAUSED_SUFFIX" && ! -e "$conf" ]]; then
    run mv "$conf$PAUSED_SUFFIX" "$conf"
    echo "  Resumed renewal of the existing certificate for $DOMAIN."
  fi
}

# Put the existing certificate (and the http -> https redirect) back into
# the freshly written nginx config. No Let's Encrypt request is involved,
# so this works whatever the DNS or Cloudflare settings are.
install_existing_certificate() {
  local cert="$EXISTING_CERT_DIR/cert.pem"
  [[ -f "$cert" ]] || cert="$EXISTING_CERT_DIR/fullchain.pem"

  local domains=(-d "$DOMAIN")
  if [[ "$ADD_WWW" == "yes" ]]; then
    domains+=(-d "www.$DOMAIN")
  fi

  certbot install --nginx --non-interactive --cert-name "$DOMAIN" \
    --cert-path "$cert" \
    --fullchain-path "$EXISTING_CERT_DIR/fullchain.pem" \
    --key-path "$EXISTING_CERT_DIR/privkey.pem" \
    "${domains[@]}" --redirect
}

get_certificate() {
  set_certbot_command

  if [[ "$WANT_CERTIFICATE" != "yes" ]]; then
    CERT_STATE="off"
    return
  fi

  step "Getting Let's Encrypt certificate"

  # certbot adds the HTTPS settings to the nginx config itself.
  # Renewal is automatic through certbot's systemd timer.
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "  [test] if a certificate for $DOMAIN exists: reinstall it (no Let's Encrypt request)"
    echo "  [test] if a new one is needed: check $SERVER_NAMES reach this server"
    echo "         (DNS, else a temporary test file); if not, stage the site"
    run "${CERTBOT_COMMAND[@]}"
    CERT_STATE="ok"
    return
  fi

  # 1. A certificate this domain already has is put straight back, so a
  #    redeploy never leaves the site without https, whatever happens next.
  local kept_existing="no"
  if existing_certificate; then
    resume_certificate_renewal    # if the site was removed and is back
    if install_existing_certificate; then
      kept_existing="yes"
      CERT_STATE="ok"
    else
      warn "couldn't reinstall the existing certificate from $EXISTING_CERT_DIR"
    fi
    if [[ "$kept_existing" == "yes" ]] && existing_certificate_is_enough; then
      return
    fi
  fi

  # 2. A new certificate is needed (none yet, a name was added, or it
  #    expires within 30 days). Only ask once every name reaches this
  #    server: setting a site up before switching DNS is normal, and a
  #    request that can't succeed counts against Let's Encrypt's limit of
  #    5 failures per hostname per hour.
  find_names_not_reaching

  if (( ${#NOT_REACHING[@]} > 0 )); then
    if [[ "$OPTION_SSL" != "yes" ]]; then
      if [[ "$kept_existing" == "yes" ]]; then
        local missing="${NOT_REACHING[*]}"
        warn "kept the existing certificate, but couldn't get an updated one because" \
             "${missing// / and } doesn't reach this server yet. Run" \
             "'sudo sitectl add $DOMAIN --yes' once DNS points here."
        return
      fi
      CERT_STATE="staged"
      explain_staged_site "${NOT_REACHING[@]}"
      return
    fi
    if (( ${#NOT_REACHING[@]} == 1 )); then
      warn "${NOT_REACHING[0]} doesn't seem to reach this server yet; trying anyway because of --ssl"
    else
      local joined="${NOT_REACHING[*]}"
      warn "${joined// / and } don't seem to reach this server yet; trying anyway because of --ssl"
    fi
  fi

  if "${CERTBOT_COMMAND[@]}"; then
    CERT_STATE="ok"
  elif [[ "$kept_existing" == "yes" ]]; then
    # The existing certificate is still installed, so https keeps working.
    warn "couldn't get an updated certificate; the existing one is still in use"
    explain_certificate_failure
  else
    # The site still works on plain HTTP, so warn rather than stop.
    CERT_STATE="failed"
    warn "certbot failed; the site is up on HTTP only"
    explain_certificate_failure
  fi
}

# Cloudflare's proxy addresses (from cloudflare.com/ips). A proxied
# (orange cloud) domain resolves to these.
CLOUDFLARE_RANGES="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22
198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13
131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32
2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"

# Returns success if an address is in one of Cloudflare's ranges.
is_cloudflare_address() {
  command -v python3 > /dev/null || return 1
  # shellcheck disable=SC2086  # the ranges are deliberately split into arguments
  python3 -c '
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if any(ip in ipaddress.ip_network(r) for r in sys.argv[2:]) else 1)
' "$1" $CLOUDFLARE_RANGES 2> /dev/null
}

# This server's own addresses, for the advice below.
find_my_addresses() {
  MY_IPS=$(ip -o addr show scope global | awk '{ split($4, a, "/"); print a[1] }')
  MY_V4=$(grep -v ':' <<< "$MY_IPS" | head -n 1 || true)
  MY_V6=$(grep ':' <<< "$MY_IPS" | head -n 1 || true)
  if [[ -z "$MY_V4" ]]; then
    MY_V4="this server's IPv4 address"
  fi
}

# Print where each name points, and set DNS_POINTS_ELSEWHERE to yes if
# any name has no record or points somewhere other than this server or
# Cloudflare's proxy.
show_where_names_point() {
  local name ip addresses
  DNS_POINTS_ELSEWHERE="no"

  echo "Where each name points (as this server looks it up):"
  for name in $SERVER_NAMES; do
    # (getent fails when there's no record; that's a result, not an error.)
    addresses=$(getent ahosts "$name" 2> /dev/null | awk '{ print $1 }' | sort -u || true)
    if [[ -z "$addresses" ]]; then
      echo "  $name: no DNS record yet"
      DNS_POINTS_ELSEWHERE="yes"
      continue
    fi
    for ip in $addresses; do
      if grep -qxF "$ip" <<< "$MY_IPS"; then
        echo "  $name -> $ip  (this server)"
      elif is_cloudflare_address "$ip"; then
        echo "  $name -> $ip  (Cloudflare proxy)"
      else
        echo "  $name -> $ip  (another server)"
        DNS_POINTS_ELSEWHERE="yes"
      fi
    done
  done
}

# The DNS change that makes the domain point here, indented by $1.
print_dns_change() {
  local i="${1:-  }"
  echo "${i}Where the domain's DNS is managed (e.g. Cloudflare), point"
  echo "${i}$SERVER_NAMES at this server:"
  echo "${i}  - A records:    $MY_V4"
  if [[ -n "$MY_V6" ]]; then
    echo "${i}  - AAAA records: $MY_V6, or delete them"
  else
    echo "${i}  - delete any AAAA (IPv6) records"
  fi
  echo "${i}  (Let's Encrypt tries IPv6 first, so a stale AAAA record also blocks it.)"
  echo "${i}For a proxied (orange cloud) record, keep the proxy on and just change"
  echo "${i}the IP address in the record."
}

# The site is set up, but its names don't reach this server yet, usually
# because DNS still points at the old server. Explain how to test it and
# how to finish.
explain_staged_site() {
  find_my_addresses

  local names="$*"
  echo
  if (( $# == 1 )); then
    echo "Staged: no certificate requested yet, because $names doesn't reach"
  else
    echo "Staged: no certificate requested yet, because ${names// / and } don't reach"
  fi
  echo "this server yet. That's normal when setting a site up before switching DNS."
  echo
  show_where_names_point

  echo
  echo "1. Test the site here before switching DNS:"
  echo "   - From your computer:  curl -H 'Host: $DOMAIN' http://$MY_V4/"
  echo "   - In a browser: add this line to your computer's hosts file"
  printf '%s\n' '     (/etc/hosts on Mac/Linux; C:\Windows\System32\drivers\etc\hosts on Windows):'
  echo "       $MY_V4  $SERVER_NAMES"
  echo "     then visit http://$DOMAIN/ (plain http: there's no certificate yet)."
  echo "     Remove the line when you're done. If the browser insists on https://,"
  echo "     the old site told it to (HSTS); test with curl instead."
  echo
  echo "2. Switch DNS when you're happy."
  print_dns_change "   "
  if [[ "$DNS_POINTS_ELSEWHERE" == "no" ]]; then
    echo "   DNS already points here or at Cloudflare. If it's proxied by Cloudflare,"
    echo "   check the record's IP address in Cloudflare (it may still be the old"
    echo "   server's), and that 'Always Use HTTPS' isn't sending the check to"
    echo "   https:// first."
  fi
  echo
  echo "3. Then get the certificate (this checks again, and requests it once"
  echo "   the domain reaches this server):"
  echo "     sudo sitectl add $DOMAIN --yes"
  echo "   If you're sure DNS is right and the check is wrong, add --ssl to"
  echo "   request it anyway."
}

# certbot ran but failed: show where each name points, and what to try.
explain_certificate_failure() {
  find_my_addresses

  echo
  show_where_names_point
  echo
  if [[ "$DNS_POINTS_ELSEWHERE" == "yes" ]]; then
    echo "To fix it:"
    print_dns_change
  else
    echo "DNS looks right, so something else stopped Let's Encrypt reaching this server:"
    echo "  - port 80 must be open:  sudo ufw allow 'Nginx Full'"
    echo "  - if the domain is proxied by Cloudflare: check the record's IP address"
    echo "    in Cloudflare (it may still be the old server's), and under SSL/TLS use"
    echo "    'Full' (not 'Full (strict)') until the certificate exists"
    echo "  - certbot's details are in /var/log/letsencrypt/letsencrypt.log"
  fi
  echo
  echo "Then try again with:"
  echo "  sudo sitectl add $DOMAIN --yes"
}
