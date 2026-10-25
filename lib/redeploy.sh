# shellcheck shell=bash
#
# sitectl library: Redeploying an existing site, and undoing a failed redeploy.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.

# -----------------------------------------------------------------------------
#  Redeploying an existing site
# -----------------------------------------------------------------------------

REDEPLOY="no"

# If the site already exists, switch to redeploy mode and use its current
# settings for anything not given on the command line.
check_for_existing_site() {
  if [[ ! -e "$NGINX_CONFIG" ]]; then
    return
  fi

  read_existing_site
  REDEPLOY="yes"

  if [[ -n "$SITE_USER" && "$SITE_USER" != "$EXISTING_USER" ]]; then
    die "$DOMAIN belongs to user $EXISTING_USER; changing the user needs 'sitectl remove $DOMAIN' first"
  fi
  SITE_USER="$EXISTING_USER"

  if ! id "$SITE_USER" &> /dev/null; then
    die "$NGINX_CONFIG says the user is $SITE_USER, but that user doesn't exist"
  fi

  if [[ -z "$OPTION_TYPE" ]]; then
    SITE_TYPE="$EXISTING_TYPE"
  fi
  if [[ -z "$OPTION_WWW" ]]; then
    ADD_WWW="$EXISTING_WWW"
  fi
}

# Show what a redeploy will do and ask before going ahead.
confirm_redeploy() {
  NEW_USER="no"
  set_user_paths

  if [[ -n "$OPTION_PATH" ]]; then
    set_web_root "$OPTION_PATH" || die "invalid --path"
  else
    set_web_root "$EXISTING_ROOT" || die "can't use web folder $EXISTING_ROOT"
  fi

  echo
  echo "$DOMAIN is already set up. Redeploying will:"
  echo "  - replace the nginx config (the old one goes to a backup folder)"
  if [[ "$SITE_TYPE" == "php" ]]; then
    echo "  - replace the PHP pool for $SITE_USER (the old one goes to a backup folder)"
    local pool_users
    if pool_users=$(other_sites_using_pool "$SITE_USER"); then
      echo "    This pool is also used by:"
      print_site_names "$pool_users"
    fi
  elif [[ "$EXISTING_TYPE" == "php" && -e "$PHP_POOL_CONFIG" ]]; then
    # Switching from PHP to static: the pool may no longer be needed.
    local pool_users
    if pool_users=$(other_sites_using_pool "$SITE_USER"); then
      echo "  - stop using PHP; keep the PHP pool for $SITE_USER, still used by:"
      print_site_names "$pool_users"
    else
      echo "  - stop using PHP, and move the PHP pool for $SITE_USER (and its"
      echo "    AppArmor rules) to the backup folder, since no other site uses it"
    fi
  fi
  if [[ "$WANT_CERTIFICATE" == "yes" ]]; then
    echo "  - reinstall the certificate (a new one is only requested if needed)"
  fi
  # Modules add their own lines (e.g. sftp: "allow SFTP logins as ...").
  run_module_hooks site_preview
  echo "It keeps the user $SITE_USER and everything in $WEB_ROOT."
  echo "Skeleton files are only copied if that folder is empty."

  warn_about_php_files
  echo
  echo "Settings: $SITE_TYPE site, www: $ADD_WWW, certificate: $WANT_CERTIFICATE"
  echo

  confirm_or_cancel "Redeploy $DOMAIN?"
}

# Move the old configs aside so fresh ones can be written.
back_up_old_configs() {
  step "Backing up old configs"

  disable_site_link
  back_up "$NGINX_CONFIG"

  if [[ "$SITE_TYPE" == "php" && -e "$PHP_POOL_CONFIG" ]]; then
    # Still PHP: move the old pool aside so a fresh one is written.
    back_up "$PHP_POOL_CONFIG"
    REPLACE_POOL="yes"
  elif [[ "$EXISTING_TYPE" == "php" ]]; then
    # Switching from PHP to static: retire the pool and its AppArmor
    # rules, unless another site still uses them.
    retire_php_pool
  fi
}

# Warn if a static site's web folder has PHP files in it, since they won't
# run (nginx returns "not found" for them). Usually means --php was wanted.
warn_about_php_files() {
  if [[ "$SITE_TYPE" != "static" || ! -d "$WEB_ROOT" ]]; then
    return
  fi

  local php_file
  php_file=$(find "$WEB_ROOT" -maxdepth 3 -name '*.php' -print -quit 2> /dev/null || true)
  if [[ -n "$php_file" ]]; then
    warn "$WEB_ROOT has PHP files (e.g. ${php_file#"$WEB_ROOT"/}), but this is a" \
         "static site, so they won't run. Use --php if the site needs PHP."
  fi
}



# -----------------------------------------------------------------------------
#  Undo a failed redeploy
# -----------------------------------------------------------------------------
#
#  A redeploy moves the old nginx config and PHP pool aside before writing
#  new ones. If any later step fails, the site would be left down, so put
#  the old, working configs back. A half-written new config is kept in the
#  backup folder (as .failed) for checking. Nothing is deleted.

restore_after_failed_redeploy() {
  local status="$1"

  # (return 0, not a bare return: in an exit handler that would hand back
  # the failed command's status, and stop the handler.)
  if [[ "$status" -eq 0 || "$REDEPLOY" != "yes" || -z "$BACKUP_DIR" || "$DRY_RUN" == "yes" ]]; then
    return 0
  fi

  echo >&2
  echo "Redeploy failed; putting the previous configs back." >&2

  # $1: the live config, $2: its backup copy
  restore_config() {
    local live="$1" saved="$2"
    [[ -f "$saved" ]] || return 0
    if [[ -f "$live" ]] && ! cmp -s "$live" "$saved"; then
      mv "$live" "$BACKUP_DIR/$(basename "$live").failed"
    fi
    if [[ ! -f "$live" ]]; then
      cp -p "$saved" "$live"
      echo "  restored $live" >&2
    fi
  }

  restore_config "$NGINX_CONFIG" "$BACKUP_DIR/$DOMAIN"
  if [[ -n "${PHP_POOL_CONFIG:-}" ]]; then
    restore_config "$PHP_POOL_CONFIG" "$BACKUP_DIR/$SITE_USER.conf"
  fi

  # The AppArmor rules too, or a restored PHP site would be blocked.
  if apparmor_in_use && [[ -f "$BACKUP_DIR/$SITE_USER" ]]; then
    restore_config "$APPARMOR_RULES_DIR/$SITE_USER" "$BACKUP_DIR/$SITE_USER"
    apparmor_parser -r "$APPARMOR_PROFILE" 2> /dev/null ||
      echo "  couldn't reload AppArmor; run: sudo apparmor_parser -r $APPARMOR_PROFILE" >&2
  fi

  if [[ -f "$NGINX_CONFIG" && ! -e "$NGINX_ENABLED_LINK" ]]; then
    ln -s "$NGINX_CONFIG" "$NGINX_ENABLED_LINK"
  fi

  if [[ -n "${PHP_VERSION:-}" ]] && "php-fpm$PHP_VERSION" -t 2> /dev/null; then
    systemctl reload "php$PHP_VERSION-fpm" 2> /dev/null ||
      echo "  couldn't reload php$PHP_VERSION-fpm; check it's running" >&2
  fi
  if nginx -t 2> /dev/null; then
    systemctl reload nginx 2> /dev/null || echo "  couldn't reload nginx; check it's running" >&2
  fi

  echo "  The site is back on its previous configs. Copies are in $BACKUP_DIR" >&2
}
