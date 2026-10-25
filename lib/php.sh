# shellcheck shell=bash
#
# sitectl library: PHP-FPM pools and their AppArmor rules.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.

# -----------------------------------------------------------------------------
#  Retiring a PHP pool
# -----------------------------------------------------------------------------
#
#  Used when this domain stops using PHP: on remove, or when a PHP site
#  is redeployed as --static. The site's old nginx config has already
#  been moved aside.

retire_php_pool() {
  if [[ ! -e "$PHP_POOL_CONFIG" ]]; then
    return
  fi

  if other_sites_using_pool "$SITE_USER" > /dev/null; then
    # Other sites still use this user's pool, so keep it. Rebuild the
    # AppArmor rules without this site, in case its web folder was
    # outside the home folder.
    update_apparmor_rules "" "$NGINX_CONFIG"
    return
  fi

  step "Removing PHP pool for $SITE_USER (no other site uses it)"
  back_up "$PHP_POOL_CONFIG"
  run systemctl reload "php$PHP_VERSION-fpm"

  # No PHP site uses this user any more, so take away its AppArmor access.
  if apparmor_in_use && [[ -f "$APPARMOR_RULES_DIR/$SITE_USER" ]]; then
    back_up "$APPARMOR_RULES_DIR/$SITE_USER"
    reload_apparmor
  fi
}



# -----------------------------------------------------------------------------
#  AppArmor rules for PHP-FPM
# -----------------------------------------------------------------------------
#
#  Ubuntu runs PHP-FPM under an AppArmor profile that doesn't allow any
#  website folders. Without extra rules, PHP fails with "Permission
#  denied" even though normal file permissions are fine.
#
#  The profile includes every file in /etc/apparmor.d/php-fpm.d/, so each
#  site user gets one file there, allowing just that user's folders:
#  their home, plus any web folder outside it (--path /srv/...).
#
#  The file is rebuilt from the site's nginx configs whenever the user's
#  sites change, and moved to the backup folder when the last one goes.

APPARMOR_PROFILE="/etc/apparmor.d/php-fpm"
APPARMOR_RULES_DIR="/etc/apparmor.d/php-fpm.d"
APPARMOR_RULES_FILE=""

# Returns success if PHP-FPM is confined by AppArmor on this server.
apparmor_in_use() {
  [[ -f "$APPARMOR_PROFILE" ]] && command -v apparmor_parser > /dev/null
}

# Reload the PHP-FPM profile. Running PHP processes pick up the change
# straight away, so PHP-FPM doesn't need restarting.
reload_apparmor() {
  run apparmor_parser -r "$APPARMOR_PROFILE"
}

# Rebuild the AppArmor rules file for SITE_USER.
#   $1  a web folder to include even if its nginx config isn't written yet
#   $2  an nginx config to leave out (e.g. the site being removed)
update_apparmor_rules() {
  local extra_root="${1:-}"
  local skip_config="${2:-}"

  if ! apparmor_in_use; then
    return
  fi

  if ! grep -q "php-fpm.d" "$APPARMOR_PROFILE"; then
    warn "$APPARMOR_PROFILE doesn't include $APPARMOR_RULES_DIR, so PHP may" \
         "be blocked from $HOME_DIR. Add rules for it to /etc/apparmor.d/local/php-fpm."
    return
  fi

  APPARMOR_RULES_FILE="$APPARMOR_RULES_DIR/$SITE_USER"

  # Every web folder PHP-FPM needs for this user: the home folder covers
  # most, plus the roots of any of the user's PHP sites outside it.
  local folders=("$HOME_DIR")
  local roots=("$extra_root")
  local config root

  while read -r config; do
    [[ -n "$config" && "$config" != "$skip_config" ]] || continue
    grep -qF "unix:/run/php/$SITE_USER.sock" "$config" || continue
    roots+=("$(sed -n 's/^[[:space:]]*root[[:space:]]\{1,\}\([^;]*\);.*/\1/p' "$config" | head -n 1)")
  done < <(site_config_files)

  for root in "${roots[@]}"; do
    # Skip blanks, folders inside the home (already covered), and repeats.
    if [[ -z "$root" || "$root" == "$HOME_DIR"/* ]]; then
      continue
    fi
    if [[ " ${folders[*]} " == *" $root "* ]]; then
      continue
    fi
    # AppArmor treats characters like * { } , as patterns, so only plain
    # paths are added automatically.
    if [[ ! "$root" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
      warn "not adding $root to AppArmor automatically (unusual characters);" \
           "add it to $APPARMOR_RULES_FILE yourself"
      continue
    fi
    folders+=("$root")
  done

  # Build the file's contents.
  # r = read, w = write (logs, sessions, uploads), k = file locking (sessions).
  # Running programs from these folders is deliberately not allowed.
  local contents folder
  contents="# AppArmor rules letting PHP-FPM use the folders of site user $SITE_USER.
# Managed by sitectl, and rebuilt whenever this user's sites change."
  for folder in "${folders[@]}"; do
    contents+="
$folder/ r,
$folder/** rwk,"
  done

  # Nothing to do if the file already says exactly this.
  if [[ -f "$APPARMOR_RULES_FILE" && "$(cat "$APPARMOR_RULES_FILE")" == "$contents" ]]; then
    return
  fi

  step "Updating AppArmor rules for $SITE_USER"

  run mkdir -p "$APPARMOR_RULES_DIR"
  if [[ -f "$APPARMOR_RULES_FILE" ]]; then
    back_up "$APPARMOR_RULES_FILE"
  fi
  write_file "$APPARMOR_RULES_FILE" <<< "$contents"

  if [[ "$DRY_RUN" == "yes" ]]; then
    reload_apparmor
    return
  fi

  # If the profile won't load, put the previous rules back so AppArmor
  # keeps working, and stop.
  if ! apparmor_parser -r "$APPARMOR_PROFILE"; then
    make_backup_dir
    mv "$APPARMOR_RULES_FILE" "$BACKUP_DIR/$SITE_USER.apparmor-failed"
    if [[ -f "$BACKUP_DIR/$SITE_USER" ]]; then
      cp -p "$BACKUP_DIR/$SITE_USER" "$APPARMOR_RULES_FILE"
    fi
    die "AppArmor wouldn't load the new rules; restored the previous ones." \
        "The failed file is $BACKUP_DIR/$SITE_USER.apparmor-failed"
  fi
}


# -----------------------------------------------------------------------------
#  Step 5: Create the PHP-FPM pool
# -----------------------------------------------------------------------------
#
#  Each site user gets its own pool, so its PHP runs as that user.
#  With one shared pool, every site's PHP would run as www-data and could
#  read and change every other site's files.

REPLACE_POOL="no"

create_php_pool() {
  if [[ "$SITE_TYPE" != "php" ]]; then
    return
  fi

  # Let PHP-FPM through AppArmor to this user's folders first, so the
  # site works as soon as the pool starts.
  update_apparmor_rules "$WEB_ROOT"

  # A user that already has a pool (from an earlier domain) reuses it,
  # unless a redeploy just moved the old one aside.
  if [[ -e "$PHP_POOL_CONFIG" && "$REPLACE_POOL" != "yes" ]]; then
    echo
    echo "==> Using existing PHP pool for $SITE_USER"
    return
  fi

  step "Creating PHP $PHP_VERSION pool"

  write_file "$PHP_POOL_CONFIG" <<EOF
; PHP-FPM pool for user $SITE_USER (managed by sitectl, first set up for $DOMAIN)

[$SITE_USER]

; Run this site's PHP as the site's own user.
user = $SITE_USER
group = $SITE_USER

; nginx talks to this pool through a socket file only www-data can use.
listen = /run/php/$SITE_USER.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

; Start PHP processes only when requests come in, and stop them when idle.
; Saves memory on a server with several quiet sites.
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 30s

; Keep PHP inside this user's home folder. Add other folders here,
; separated by ':', if a site's web folder is outside the home.
php_admin_value[open_basedir] = $HOME_DIR/

; Use the user's own tmp folder rather than the shared /tmp.
php_admin_value[upload_tmp_dir] = $TMP_DIR
php_admin_value[sys_temp_dir] = $TMP_DIR
php_admin_value[session.save_path] = $TMP_DIR

; Write PHP errors to the user's own log.
php_admin_flag[log_errors] = on
php_admin_value[error_log] = $LOG_DIR/php-error.log
EOF

  # Test the PHP-FPM config before reloading, so a mistake can't take
  # down the other sites.
  run "php-fpm$PHP_VERSION" -t
  run systemctl reload "php$PHP_VERSION-fpm"
}
