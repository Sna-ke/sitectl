# shellcheck shell=bash
#
# sitectl library: The summary printed at the end of add.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.

# -----------------------------------------------------------------------------
#  Finish: print a summary
# -----------------------------------------------------------------------------

print_summary() {
  local url="http://$DOMAIN/"
  if [[ "$CERT_STATE" == "ok" ]]; then
    url="https://$DOMAIN/"
  fi

  local user_note="new"
  if [[ "$NEW_USER" != "yes" ]]; then
    user_note="existing"
  fi

  echo
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Test run for $DOMAIN: nothing was changed. A real run would give:"
  elif [[ "$REDEPLOY" == "yes" ]]; then
    echo "Redeployed: $DOMAIN"
  else
    echo "Done: $DOMAIN"
  fi
  echo "  URL:        $url"
  echo "  User:       $SITE_USER ($user_note)"
  echo "  Web root:   $WEB_ROOT"
  echo "  Private:    $PRIVATE_DIR  (not served; the site's code can use it)"
  echo "  nginx:      $NGINX_CONFIG"

  if [[ "$SITE_TYPE" == "php" ]]; then
    echo "  PHP pool:   $PHP_POOL_CONFIG"
    if [[ -n "$APPARMOR_RULES_FILE" ]]; then
      echo "  AppArmor:   $APPARMOR_RULES_FILE"
    fi
    # The pool only starts PHP processes when a request comes in,
    # so load the site first, then check which user they run as.
    echo "  PHP check:  load the site, then: pgrep -a -u $SITE_USER php-fpm"
  fi

  if [[ -n "$BACKUP_DIR" && "$DRY_RUN" != "yes" ]]; then
    echo "  Old configs: $BACKUP_DIR"
  fi

  case "$CERT_STATE" in
    ok)     echo "  Certificate: yes (https, with http redirected to it)" ;;
    staged) echo "  Certificate: not yet: staged until DNS points here (steps above)" ;;
    failed) echo "  Certificate: failed (see above); the site is on http for now" ;;
    off)    echo "  Certificate: off. To add one: sudo sitectl add $DOMAIN --ssl --yes" ;;
  esac

  # Modules add their own lines (e.g. sftp: how to connect).
  run_module_hooks site_summary

  if [[ "$OUTSIDE_HOME" == "yes" ]]; then
    echo
    echo "Note: $WEB_ROOT is outside $HOME_DIR. Make sure www-data can read it"
    echo "and $SITE_USER can write to it."
    if [[ "$SITE_TYPE" == "php" ]]; then
      echo "PHP is limited to $HOME_DIR by open_basedir in $PHP_POOL_CONFIG;"
      echo "add $WEB_ROOT there and reload php$PHP_VERSION-fpm."
    fi
  fi
}
