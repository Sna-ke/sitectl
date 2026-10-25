# shellcheck shell=bash
#
# sitectl library: Names, paths, reading existing sites, and prerequisite checks.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.

# -----------------------------------------------------------------------------
#  Work out the username, paths and PHP version
# -----------------------------------------------------------------------------

# Returns success if a username is in a valid format.
valid_username() {
  [[ "$1" =~ ^[a-z][a-z0-9_]{0,31}$ ]]
}

# Returns success if an existing user looks like one this script created:
# a regular (not system) account with no login shell, whose home is
# /home/<user> and owned by root. That rules out your own login, and
# system accounts like syslog or nobody.
is_site_user() {
  local user="$1"
  local uid home shell
  IFS=: read -r _ _ uid _ _ home shell < <(getent passwd "$user") || return 1

  [[ "$shell" == "/usr/sbin/nologin" ]] || return 1
  [[ "$uid" -ge 1000 && "$uid" -lt 60000 ]] || return 1
  [[ "$home" == "/home/$user" && -d "$home" && ! -L "$home" ]] || return 1
  [[ "$(stat -c %U "$home")" == "root" ]]
}

# Paths that depend only on the domain, plus the PHP version.
set_domain_paths() {
  # nginx: the config lives in sites-available; a link in sites-enabled
  # turns it on. One config file per domain.
  NGINX_CONFIG="/etc/nginx/sites-available/$DOMAIN"
  NGINX_ENABLED_LINK="/etc/nginx/sites-enabled/$DOMAIN"

  # Find the newest PHP version that has PHP-FPM installed (e.g. 8.5).
  # Leftover folders in /etc/php from removed versions are skipped.
  PHP_VERSION=""
  local version
  if [[ -d /etc/php ]]; then
    for version in $(find /etc/php -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V); do
      if [[ "$version" =~ ^[0-9]+\.[0-9]+$ && -d "/etc/php/$version/fpm/pool.d" ]] &&
         command -v "php-fpm$version" > /dev/null; then
        PHP_VERSION="$version"
      fi
    done
  fi
}

# Print this script's site configs in sites-available, one per line.
# Only files named like a domain count, so editor leftovers such as
# "example.com~" or "example.com.save" are ignored. With "any", configs
# made by hand are included too.
site_config_files() {
  local which="${1:-ours}"
  local config name
  local domain_pattern='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$'
  for config in /etc/nginx/sites-available/*; do
    name="${config##*/}"
    [[ -f "$config" && "$name" =~ $domain_pattern ]] || continue
    if [[ "$which" != "any" ]]; then
      is_managed_config "$config" || continue
    fi
    echo "$config"
  done
}

# Print the domains (other than this one) whose site user is $1.
other_domains_for_user() {
  local config others=""
  while read -r config; do
    [[ -n "$config" && "$config" != "$NGINX_CONFIG" ]] || continue
    if [[ "$(site_user_from_config "$config")" == "$1" ]]; then
      others+=" ${config##*/}"
    fi
  done < <(site_config_files)
  echo "$others"
}

# The username and the hostnames nginx answers to.
set_user_and_server_names() {
  # Turn the domain into a username by removing dots and hyphens:
  #   example.com -> examplecom
  if [[ -z "$SITE_USER" ]]; then
    SITE_USER="${DOMAIN//[.-]/}"

    # Usernames have to start with a letter (e.g. for 123domain.com).
    if [[ ! "$SITE_USER" =~ ^[a-z] ]]; then
      SITE_USER="s$SITE_USER"
    fi

    # Linux usernames are limited to 32 characters.
    SITE_USER="${SITE_USER:0:32}"
  fi

  if ! valid_username "$SITE_USER"; then
    die "invalid username: $SITE_USER"
  fi

  SERVER_NAMES="$DOMAIN"
  if [[ "$ADD_WWW" == "yes" ]]; then
    SERVER_NAMES="$DOMAIN www.$DOMAIN"
  fi
}

# Set the paths that depend on the username. Called once the user is decided.
set_user_paths() {
  HOME_DIR="/home/$SITE_USER"
  LOG_DIR="$HOME_DIR/logs"
  TMP_DIR="$HOME_DIR/tmp"
  PRIVATE_DIR="$HOME_DIR/private"
  PHP_POOL_CONFIG="/etc/php/$PHP_VERSION/fpm/pool.d/$SITE_USER.conf"
}


# -----------------------------------------------------------------------------
#  Reading an existing site (for redeploy and remove)
# -----------------------------------------------------------------------------

# Load an existing site by domain, for module commands: sets DOMAIN,
# NGINX_CONFIG, SITE_USER, HOME_DIR, WEB_ROOT, SITE_TYPE and the paths
# that go with them. Stops if the site isn't managed by sitectl.
load_site() {
  set_domain "$1"
  set_domain_paths
  [[ -e "$NGINX_CONFIG" ]] || die "$DOMAIN isn't set up here (see: sitectl list)"
  read_existing_site
  SITE_USER="$EXISTING_USER"
  set_user_paths
  WEB_ROOT="$EXISTING_ROOT"
  SITE_TYPE="$EXISTING_TYPE"
}

# Combine the settings file with the command-line options.
# Command-line options win.
apply_options() {
  SITE_TYPE="${OPTION_TYPE:-$DEFAULT_SITE_TYPE}"
  ADD_WWW="${OPTION_WWW:-$INCLUDE_WWW}"
  WANT_CERTIFICATE="${OPTION_SSL:-$GET_CERTIFICATE}"
}

# Returns success if an nginx config was written by sitectl (or by its
# earlier name, add-new-site). Configs made by hand are never touched.
is_managed_config() {
  grep -qE 'managed by sitectl|created by add-new-site' "$1"
}

# Print the site user from the "# Site user: examplecom" line this
# script writes into each nginx config.
site_user_from_config() {
  sed -n 's/^# Site user: \([a-z0-9_]*\).*/\1/p' "$1" | head -n 1
}

# Read the user, web folder and settings back out of a site's nginx
# config. Only configs this script wrote are trusted.
read_existing_site() {
  if ! is_managed_config "$NGINX_CONFIG"; then
    die "$NGINX_CONFIG isn't managed by sitectl, so leaving it alone"
  fi

  EXISTING_USER=$(site_user_from_config "$NGINX_CONFIG")

  # From the first "root /path;" line.
  EXISTING_ROOT=$(sed -n 's/^[[:space:]]*root[[:space:]]\{1,\}\([^;]*\);.*/\1/p' "$NGINX_CONFIG" | head -n 1)

  # PHP sites have a fastcgi_pass line; static sites don't.
  EXISTING_TYPE="static"
  if grep -q "fastcgi_pass" "$NGINX_CONFIG"; then
    EXISTING_TYPE="php"
  fi

  # Does the first server_name line include www.<domain>?
  EXISTING_WWW="no"
  if grep -m 1 "server_name" "$NGINX_CONFIG" | grep -qF " www.$DOMAIN"; then
    EXISTING_WWW="yes"
  fi

  if [[ -z "$EXISTING_USER" || -z "$EXISTING_ROOT" ]]; then
    die "couldn't read the site user and web folder from $NGINX_CONFIG"
  fi
}

# Returns success (and prints the other config files) if any other site's
# nginx config uses this user's PHP pool.
other_sites_using_pool() {
  local user="$1"
  local others="" config
  # Includes configs made by hand, so a pool they use is never retired.
  while read -r config; do
    [[ -n "$config" && "$config" != "$NGINX_CONFIG" ]] || continue
    if grep -qF "unix:/run/php/$user.sock" "$config"; then
      others+="$config"$'\n'
    fi
  done < <(site_config_files any)
  others="${others%$'\n'}"
  if [[ -n "$others" ]]; then
    echo "$others"
    return 0
  fi
  return 1
}

# Print config file paths as indented site names (just the file names).
print_site_names() {
  local file
  for file in $1; do
    echo "      ${file##*/}"
  done
}

# Returns success if Let's Encrypt has a certificate named after the domain.
# (Needs sudo to see; without it, this says no.)
has_certificate() {
  [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]
}



# -----------------------------------------------------------------------------
#  Step 1: Check everything is in place before changing anything
# -----------------------------------------------------------------------------

check_prerequisites() {
  step "Checking prerequisites"

  if ! command -v nginx > /dev/null; then
    die "nginx isn't installed (sudo apt install nginx)"
  fi

  # For a new site, nothing may exist yet. (A redeploy replaces these.)
  if [[ "$REDEPLOY" != "yes" ]]; then
    # -L also catches a broken symlink, which -e would miss.
    if [[ -e "$NGINX_ENABLED_LINK" || -L "$NGINX_ENABLED_LINK" ]]; then
      die "$NGINX_ENABLED_LINK already exists"
    fi
  fi

  if [[ "$SITE_TYPE" == "php" ]]; then
    if [[ -z "$PHP_VERSION" || ! -d "/etc/php/$PHP_VERSION/fpm/pool.d" ]]; then
      die "php-fpm isn't installed (sudo apt install php-fpm), or use --static"
    fi
  fi

  if [[ "$WANT_CERTIFICATE" == "yes" ]]; then
    if ! command -v certbot > /dev/null; then
      die "certbot isn't installed (sudo apt install certbot python3-certbot-nginx)"
    fi
    if [[ -z "$CERTBOT_EMAIL" ]]; then
      die "no Let's Encrypt email set; run 'sudo sitectl config' (or use --no-ssl)"
    fi
  fi
}
