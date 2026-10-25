# shellcheck shell=bash
#
# sitectl library: Site users, web folders, the private folder and skeleton files.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.

# -----------------------------------------------------------------------------
#  Step 2: Decide which user and web folder this domain uses
# -----------------------------------------------------------------------------

# Suggest the next free username: examplecom2, examplecom3, ...
next_free_username() {
  local base="${1:0:30}"
  local n=2
  while id "$base$n" &> /dev/null; do
    n=$((n + 1))
  done
  echo "$base$n"
}

# Turn a --path value (or answer) into the full web folder path.
#   www                ->  /home/<user>/www
#   /var/www/example   ->  /var/www/example   (used as is)
# Returns failure, with a message, if the path isn't usable.
set_web_root() {
  local path="${1%/}"    # drop a trailing slash

  # Only plain path characters. The path goes into the nginx config and
  # the AppArmor rules, where characters like ; { } * would change their
  # meaning (or break them).
  if [[ ! "$path" =~ ^[A-Za-z0-9._/-]+$ || "$path" == *..* || "$path" == *//* ]]; then
    echo "  '$1' isn't a usable path (letters, numbers, . _ - and / only, no '..')." >&2
    return 1
  fi

  if [[ "$path" == /* ]]; then
    # Never a system folder: nginx would serve it to the world, and the
    # AppArmor rules would let PHP write to it.
    if [[ "$path" =~ ^/(bin|boot|dev|etc|lib|lib32|lib64|libx32|proc|root|run|sbin|snap|sys|usr)(/|$) ||
          "$path" =~ ^/var/(backups|cache|lib|local|lock|log|mail|opt|run|spool|tmp)(/|$) ||
          "$path" =~ ^/(home|media|mnt|opt|srv|tmp|var)?$ ]]; then
      echo "  $path is a system folder; pick a folder of its own, like /srv/www/example." >&2
      return 1
    fi
    WEB_ROOT="$path"
  else
    WEB_ROOT="$HOME_DIR/$path"
  fi

  # Inside the user's home, the web folder can't be the home folder
  # itself, or one of the folders kept out of public view: serving them
  # would publish private files, logs or session data.
  if [[ "$WEB_ROOT" == "$HOME_DIR" || "$WEB_ROOT" == "$HOME_DIR/." ]]; then
    echo "  The web folder can't be $HOME_DIR itself (it holds private, logs and tmp)." >&2
    return 1
  fi
  if [[ "$WEB_ROOT" == "$HOME_DIR"/* ]]; then
    local first="${WEB_ROOT#"$HOME_DIR"/}"
    first="${first%%/*}"
    case "$first" in
      private|logs|tmp|.ssh|.)
        echo "  $first is kept out of public view, so it can't be (part of) a web folder." >&2
        return 1
        ;;
    esac
  fi
}

# Returns success if another site already serves this exact folder.
folder_used_by_other_site() {
  local folder="$1" config root
  while read -r config; do
    [[ -n "$config" && "$config" != "$NGINX_CONFIG" ]] || continue
    root=$(sed -n 's/^[[:space:]]*root[[:space:]]\{1,\}\([^;]*\);.*/\1/p' "$config" | head -n 1)
    if [[ "$root" == "$folder" ]]; then
      return 0
    fi
  done < <(site_config_files)
  return 1
}

# Use --path if given; otherwise ask (if adding to an existing user and
# someone's at the keyboard) or use the default.
#
# The default is the settings file's folder (public_html). When adding
# another domain to an existing user whose public_html is already in use,
# the default is instead a folder named after the domain, next to it:
#   /home/examplecom/example.net
# so the two sites don't share files by accident. (For an alias that
# should show the same files, pass --path public_html.)
choose_web_root() {
  local should_ask="$1"
  local default="$DEFAULT_PATH"
  local answer

  if [[ -n "$OPTION_PATH" ]]; then
    set_web_root "$OPTION_PATH" || die "invalid --path"
    return
  fi

  if [[ "$NEW_USER" != "yes" ]]; then
    set_web_root "$DEFAULT_PATH" || die "invalid DEFAULT_PATH in $CONFIG_FILE"
    if folder_used_by_other_site "$WEB_ROOT"; then
      default="$DOMAIN"
    fi
  fi

  if [[ "$should_ask" == "yes" ]] && can_ask; then
    while true; do
      ask "Web folder for $DOMAIN (relative to $HOME_DIR, or absolute)" \
          answer "$default"
      if set_web_root "$answer"; then
        return
      fi
    done
  fi

  set_web_root "$default" || die "invalid web folder: $default"
}

choose_user() {
  # The common case: the username is free, so create it.
  if ! id "$SITE_USER" &> /dev/null; then
    NEW_USER="yes"
    set_user_paths
    if [[ -e "$HOME_DIR" ]]; then
      die "$HOME_DIR already exists but there's no user $SITE_USER; check it first"
    fi
    choose_web_root "no"
    return
  fi

  # The username exists. Only offer to share it if it's a site user,
  # not something like your own login or a system account.
  if ! is_site_user "$SITE_USER"; then
    die "user $SITE_USER already exists and isn't a website user; use --user to pick another name"
  fi

  # Naming the user with --user is a clear choice to add this domain to
  # it, and --use-existing-user answers the question ahead of time.
  # Otherwise the name only matched by accident (exam-ple.com and
  # example.com both make examplecom), so ask below.
  if [[ "$USER_GIVEN" == "yes" || "$USE_EXISTING_USER" == "yes" ]]; then
    echo "Adding $DOMAIN to existing user $SITE_USER."
    NEW_USER="no"
    set_user_paths
    choose_web_root "yes"
    return
  fi

  if ! can_ask; then
    die "user $SITE_USER already exists; add --use-existing-user or --user NAME"
  fi

  echo
  echo "User $SITE_USER already exists ($DOMAIN maps to the same username)."
  echo "  1) Create a different user for $DOMAIN"
  echo "  2) Add $DOMAIN to $SITE_USER (shares its files and PHP pool)"
  echo "  3) Cancel"

  local choice
  ask "Choose" choice "1"

  case "$choice" in
    1)
      local new_name
      while true; do
        ask "New username" new_name "$(next_free_username "$SITE_USER")"
        if ! valid_username "$new_name"; then
          echo "  Use lowercase letters, numbers and _, starting with a letter (max 32)."
        elif id "$new_name" &> /dev/null; then
          echo "  $new_name already exists."
        elif [[ -e "/home/$new_name" ]]; then
          echo "  /home/$new_name already exists."
        else
          break
        fi
      done
      SITE_USER="$new_name"
      NEW_USER="yes"
      set_user_paths
      choose_web_root "no"
      ;;
    2)
      NEW_USER="no"
      set_user_paths
      choose_web_root "yes"
      ;;
    *)
      echo "Cancelled; nothing was changed."
      exit 0
      ;;
  esac
}


# -----------------------------------------------------------------------------
#  Step 3: Create the site user and web folder
# -----------------------------------------------------------------------------

create_user() {
  if [[ "$NEW_USER" != "yes" ]]; then
    return
  fi

  step "Creating user $SITE_USER"

  # A system user with no login shell. -U also creates a matching group.
  # -M skips copying the usual .bashrc etc., since nobody logs in as it.
  run useradd -M -d "$HOME_DIR" -s /usr/sbin/nologin -U "$SITE_USER"

  # The home folder is owned by root, readable by the site's group.
  # The site can't rename or replace its own folders, and it also means
  # the folder can be used as an SFTP chroot later if you want that.
  run install -d -o root -g "$SITE_USER" -m 750 "$HOME_DIR"

  # Folders the site itself owns and can write to.
  run install -d -o "$SITE_USER" -g "$SITE_USER" -m 750 "$LOG_DIR"
  run install -d -o "$SITE_USER" -g "$SITE_USER" -m 700 "$TMP_DIR"

  # nginx runs as www-data. Adding www-data to the site's group lets it
  # read the site's files, while other sites' users still can't.
  run usermod -aG "$SITE_USER" www-data
}

# The private folder: for config files, keys, data and anything else the
# site's code needs but visitors must never download. It sits next to
# public_html, so nginx never serves it, and it's mode 700, so only the
# site user (which PHP runs as) can read it; nginx can't, even by mistake.
# One per user, shared by all of that user's sites. From a site's code:
#   require __DIR__ . '/../private/config.php';
# Users created before this existed get it on their next redeploy.
create_private_folder() {
  if [[ -L "$PRIVATE_DIR" ]]; then
    die "$PRIVATE_DIR is a symlink; refusing to use it"
  fi
  if [[ ! -d "$PRIVATE_DIR" ]]; then
    # The home folder is root-owned, so root creating this is safe.
    run install -d -o "$SITE_USER" -g "$SITE_USER" -m 700 "$PRIVATE_DIR"
  fi
}

create_web_root() {
  if [[ "$WEB_ROOT" == "$HOME_DIR"/* ]]; then
    local relative="${WEB_ROOT#"$HOME_DIR"/}"
    local first="${relative%%/*}"

    # Refuse a path that runs through a symlink: the site user can create
    # those, and could point one at a folder elsewhere on the server.
    local path="$HOME_DIR" part parts
    IFS="/" read -r -a parts <<< "$relative"
    for part in "${parts[@]}"; do
      path="$path/$part"
      if [[ -L "$path" ]]; then
        die "$path is a symlink; refusing to use it as (part of) the web folder"
      fi
    done

    # The first level sits in the root-owned home folder, so root creates
    # it, owned by the site user.
    if [[ ! -d "$HOME_DIR/$first" ]]; then
      run install -d -o "$SITE_USER" -g "$SITE_USER" -m 750 "$HOME_DIR/$first"
    fi

    # Deeper levels (e.g. public_html/sub) are inside a folder the site
    # user owns, so they're created as that user. Root never works inside
    # a folder the site itself can change.
    if [[ "$relative" == */* && ! -d "$WEB_ROOT" ]]; then
      run runuser -u "$SITE_USER" -- mkdir -p -m 750 "$WEB_ROOT"
    fi
  else
    # Outside the user's home: create the folder if needed, but leave
    # permissions on it and the folders above it to you.
    if [[ ! -d "$WEB_ROOT" ]]; then
      run mkdir -p "$WEB_ROOT"
      run chown "$SITE_USER:$SITE_USER" "$WEB_ROOT"
    fi
    OUTSIDE_HOME="yes"
  fi
}


# -----------------------------------------------------------------------------
#  Step 4: Copy in the skeleton files
# -----------------------------------------------------------------------------

copy_skeleton() {
  local skeleton="$SKEL_DIR/$SITE_TYPE"

  # Only ever copy into an empty folder, so existing website files are
  # never overwritten (e.g. on a redeploy, or a domain sharing a folder).
  if [[ -d "$WEB_ROOT" && -n "$(ls -A "$WEB_ROOT")" ]]; then
    echo
    echo "==> $WEB_ROOT already has files; not copying skeleton"
    return
  fi

  # In test mode on a first run, the skeleton hasn't been created yet.
  if [[ ! -d "$skeleton" && "$DRY_RUN" == "yes" ]]; then
    step "Copying skeleton files from $skeleton"
    echo "  [test] would copy the default skeleton files into $WEB_ROOT"
    return
  fi

  if [[ ! -d "$skeleton" ]]; then
    warn "no skeleton folder at $skeleton; leaving $WEB_ROOT empty"
    return
  fi

  step "Copying skeleton files from $skeleton"

  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "  [test] would copy into $WEB_ROOT, owned by $SITE_USER:"
    find "$skeleton" -mindepth 1 -printf '  |  %P\n'
    echo "  [test] would replace {{DOMAIN}} with $DOMAIN and {{USER}} with $SITE_USER"
    return
  fi

  # Copy and fill in the files as the site user, not as root. The web
  # folder belongs to the site, so root working inside it could be tricked
  # by a symlink into changing files elsewhere. As the site user, the
  # copies are also owned by the right user from the start.
  #
  # Copies everything, including hidden files like .htaccess or .user.ini.
  if ! runuser -u "$SITE_USER" -- cp -R "$skeleton/." "$WEB_ROOT/"; then
    warn "couldn't copy the skeleton as $SITE_USER; can it write to $WEB_ROOT," \
         "and read $skeleton?"
    return
  fi

  # Fill in {{DOMAIN}} and {{USER}} in any files that use them.
  # shellcheck disable=SC2016  # $1-$3 are expanded by the inner sh
  runuser -u "$SITE_USER" -- sh -c '
    grep -rlZ -e "{{DOMAIN}}" -e "{{USER}}" "$1" |
      xargs -0 -r sed -i -e "s/{{DOMAIN}}/$2/g" -e "s/{{USER}}/$3/g"
  ' sh "$WEB_ROOT" "$DOMAIN" "$SITE_USER" || warn "couldn't fill in {{DOMAIN}}/{{USER}} in $WEB_ROOT"
}
