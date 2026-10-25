# shellcheck shell=bash
#
# sitectl library: Subdomains: finding the main site and choosing the user.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.

# -----------------------------------------------------------------------------
#  Subdomains
# -----------------------------------------------------------------------------
#
#  sub.example.com counts as a subdomain if example.com is already set up
#  on this server by this script. For a.b.example.com it checks
#  b.example.com, then example.com, and uses the first one it finds.
#
#  A subdomain's web folder goes next to public_html, not inside it, so
#  its files aren't also reachable at example.com/sub/ and can't be wiped
#  by deploying the main site.

PARENT_DOMAIN=""
PARENT_USER=""

find_parent_site() {
  local candidate="${DOMAIN#*.}"    # drop the first part: sub.example.com -> example.com
  local config user

  # Keep going while there are at least two parts left (example.com).
  while [[ "$candidate" == *.* ]]; do
    config="/etc/nginx/sites-available/$candidate"

    if [[ -f "$config" ]] && is_managed_config "$config"; then
      user=$(site_user_from_config "$config")
      if [[ -n "$user" ]] && id "$user" &> /dev/null; then
        PARENT_DOMAIN="$candidate"
        PARENT_USER="$user"

        # www.sub.example.com is rarely wanted, and asking for a
        # certificate for it fails if it has no DNS record.
        if [[ -z "$OPTION_WWW" ]]; then
          ADD_WWW="no"
        fi
        return
      fi
    fi

    candidate="${candidate#*.}"
  done
}

# add-subdomain: the main domain must already be set up here by
# this script; its user is the one the subdomain joins.
use_main_domain_as_parent() {
  local config="/etc/nginx/sites-available/$MAIN_DOMAIN"
  local user

  if [[ ! -f "$config" ]]; then
    die "$MAIN_DOMAIN isn't set up on this server yet. Add it first:" \
        "sudo sitectl add $MAIN_DOMAIN"
  fi
  if ! is_managed_config "$config"; then
    die "$config isn't managed by sitectl, so there's no site user to add" \
        "$DOMAIN to. Use: sudo sitectl add $DOMAIN --user NAME"
  fi

  user=$(site_user_from_config "$config")
  if [[ -z "$user" ]] || ! id "$user" &> /dev/null; then
    die "couldn't find the site user for $MAIN_DOMAIN (from $config)"
  fi

  PARENT_DOMAIN="$MAIN_DOMAIN"
  PARENT_USER="$user"

  # Subdomains don't get www.<subdomain> unless asked for.
  if [[ -z "$OPTION_WWW" ]]; then
    ADD_WWW="no"
  fi
}

# Decide whether a subdomain shares the main domain's user. The default
# is to share; --separate-user, or choosing it at the prompt, gives the
# subdomain its own user instead. With add-subdomain there's no
# question: it joins the main domain's user unless --separate-user.
choose_subdomain_user() {
  local choice="1"

  echo
  echo "$DOMAIN is a subdomain of $PARENT_DOMAIN (user $PARENT_USER)."

  if [[ "$SEPARATE_USER" == "yes" ]]; then
    choice="2"
  elif [[ -n "$MAIN_DOMAIN" ]]; then
    echo "Adding it to $PARENT_USER, next to $PARENT_DOMAIN."
  elif can_ask; then
    echo "  1) Use $PARENT_USER (shares its files and PHP pool)"
    echo "  2) Create a separate user for $DOMAIN"
    echo "  3) Cancel"
    ask "Choose" choice "1"
  else
    echo "Using $PARENT_USER. (Add --separate-user or --user NAME for its own user.)"
  fi

  case "$choice" in
    1)
      SITE_USER="$PARENT_USER"
      NEW_USER="no"
      set_user_paths
      # Default folder is named after the subdomain, next to public_html:
      #   /home/examplecom/sub.example.com
      if [[ -n "$OPTION_PATH" ]]; then
        set_web_root "$OPTION_PATH" || die "invalid --path"
      else
        set_web_root "$DOMAIN" || die "can't use $HOME_DIR/$DOMAIN as the web folder"
      fi
      ;;
    2)
      # Carry on as a normal new site, with the username worked out from
      # the subdomain (sub.example.com -> subexamplecom).
      choose_user
      ;;
    *)
      echo "Cancelled; nothing was changed."
      exit 0
      ;;
  esac
}
