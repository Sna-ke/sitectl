# shellcheck shell=bash
#
# sitectl library: sitectl remove.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.

# -----------------------------------------------------------------------------
#  sitectl remove
# -----------------------------------------------------------------------------

remove_site() {
  if [[ ! -e "$NGINX_CONFIG" ]]; then
    die "$DOMAIN isn't set up here (no $NGINX_CONFIG)"
  fi

  read_existing_site
  SITE_USER="$EXISTING_USER"
  set_user_paths

  # Only a PHP site uses the pool; a static site never touches it.
  local remove_pool="no"
  local pool_users=""
  if [[ "$EXISTING_TYPE" == "php" && -e "$PHP_POOL_CONFIG" ]]; then
    if pool_users=$(other_sites_using_pool "$SITE_USER"); then
      remove_pool="no"
    else
      remove_pool="yes"
    fi
  fi

  # The certificate is kept, so re-adding the site (or moving it back)
  # needs no new request; only its renewal is paused, since there's no
  # site left to renew it for. An expired certificate is no use to keep.
  local cert_action="none"
  if has_certificate; then
    if certificate_has_expired; then
      cert_action="delete"
    else
      cert_action="pause"
    fi
  fi

  echo
  echo "Removing $DOMAIN will:"
  echo "  - disable the site and move its nginx config to a backup folder"
  if [[ "$remove_pool" == "yes" ]]; then
    echo "  - move the PHP pool for $SITE_USER to the backup folder (no other site uses it)"
    if [[ -f "$APPARMOR_RULES_DIR/$SITE_USER" ]]; then
      echo "    and its AppArmor rules ($APPARMOR_RULES_DIR/$SITE_USER)"
    fi
  elif [[ -n "$pool_users" ]]; then
    echo "  - keep the PHP pool for $SITE_USER, which is also used by:"
    print_site_names "$pool_users"
  fi
  case "$cert_action" in
    pause)  echo "  - keep the certificate for $DOMAIN, but pause its renewal (re-adding"
            echo "    the site reuses it and resumes renewal)" ;;
    delete) echo "  - delete the certificate for $DOMAIN, which has expired" ;;
    none)   if [[ $EUID -ne 0 ]]; then
              echo "  - keep any certificate, pausing its renewal (can't check without sudo)"
            fi ;;
  esac
  echo "It keeps the user $SITE_USER and everything in $EXISTING_ROOT."
  echo

  confirm_or_cancel "Remove $DOMAIN?"

  step "Disabling $DOMAIN"
  disable_site_link
  back_up "$NGINX_CONFIG"

  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "  [test] nginx -t, then systemctl reload nginx"
  elif nginx -t; then
    systemctl reload nginx
  else
    warn "nginx config test failed after removing $DOMAIN; nginx was not reloaded"
  fi

  if [[ "$EXISTING_TYPE" == "php" ]]; then
    retire_php_pool
  fi

  case "$cert_action" in
    pause)
      step "Pausing certificate renewal"
      pause_certificate_renewal
      ;;
    delete)
      step "Deleting expired certificate"
      run certbot delete --cert-name "$DOMAIN" --non-interactive
      ;;
  esac

  echo
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "Test run: nothing was changed."
  else
    echo "Removed $DOMAIN."
    echo "  Old configs:  $BACKUP_DIR"
  fi
  echo "  Kept:         user $SITE_USER and the files in $EXISTING_ROOT"
  if [[ "$cert_action" == "pause" ]]; then
    echo "  Certificate:  kept, renewal paused (it's reused if you add $DOMAIN again)"
  fi
  echo "  To delete the user too: sudo userdel $SITE_USER  (files stay; remove them yourself if wanted)"
}
