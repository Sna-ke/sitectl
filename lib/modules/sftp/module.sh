# shellcheck shell=bash
#
# The sftp module (ships with sitectl): SFTP logins for site users,
# jailed ("chrooted") to their home folder, so uploads are owned by the
# right user and can't reach anything else on the server.
#
#   sudo sitectl add example.com --sftp-key ~/.ssh/id_ed25519.pub
#   sitectl sftp status
#   sudo sitectl sftp add-key example.com ~/.ssh/laptop.pub
#   sudo sitectl sftp remove-key example.com SHA256:abc...
#
# SFTP is per site user, not per domain: a subdomain or extra domain on
# the same user shares the login, which reaches all of that user's
# folders. Keys live in /etc/ssh/sftp-keys/<user>, owned by root, so
# they can't be changed over SFTP.

# -----------------------------------------------------------------------------
#  SFTP (--sftp)
# -----------------------------------------------------------------------------
#
#  Members of the sftponly group can only use SFTP, locked ("jailed") into
#  their home folder. SSH requires that folder to be owned by root and not
#  writable by anyone else, which is how this script creates site homes.
#
#  A subdomain sharing its main domain's user shares that SFTP login:
#  inside the jail you see public_html, sub.example.com, logs and tmp.

SFTP_GROUP="sftponly"
SFTP_SSHD_CONFIG="/etc/ssh/sshd_config.d/50-sitectl-sftp.conf"
SFTP_KEY_LINE=""
SFTP_KEYS_FILE=""
SFTP_KEY_STATUS=""

# Check a public key (a .pub file, or the key itself) and keep it in
# SFTP_KEY_LINE. Stops with an error if it isn't a valid public key.
read_public_key() {
  local input="$1"
  local key

  if [[ -f "$input" ]]; then
    if grep -q "PRIVATE KEY" "$input"; then
      die "$input is a private key. Give the public one (usually the same name ending in .pub)."
    fi
    key=$(grep -vE '^[[:space:]]*(#|$)' "$input" | head -n 1)
  else
    key="$input"
  fi
  key="${key%$'\r'}"    # drop a Windows line ending, if pasted from one

  local key_pattern='^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$'
  if [[ ! "$key" =~ $key_pattern ]] || ! ssh-keygen -l -f /dev/stdin <<< "$key" > /dev/null 2>&1; then
    die "that doesn't look like an SSH public key (it should start with ssh-ed25519, ssh-rsa or ecdsa-...)"
  fi

  SFTP_KEY_LINE="$key"
}

# Before anything changes: check SSH is installed, and get the public key
# (from --sftp-key, or by asking).
prepare_sftp() {
  if ! sftp_wanted; then
    return
  fi

  if ! command -v sshd > /dev/null; then
    die "the SSH server isn't installed (sudo apt install openssh-server)"
  fi

  SFTP_KEY_INPUT="${MODULE_OPTIONS[--sftp-key]:-${MODULE_OPTIONS[--sftpkey]:-}}"
  if [[ -z "$SFTP_KEY_INPUT" ]] && can_ask; then
    echo
    echo "Public key allowed to log in to $SITE_USER by SFTP."
    read -r -p "Paste it, or give the path to a .pub file (Enter to skip): " SFTP_KEY_INPUT
  fi

  if [[ -n "$SFTP_KEY_INPUT" ]]; then
    read_public_key "$SFTP_KEY_INPUT"
  fi
}

# Returns success if sshd already has a "Match Group sftponly" section,
# whether from this script or set up by hand.
sftp_jail_configured() {
  grep -sqE "^[[:space:]]*Match[[:space:]]+Group[[:space:]]+([^[:space:]]*,)?$SFTP_GROUP(,|[[:space:]]|$)" \
       /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf
}

# One-time setup: the sftponly group and the SSH jail rules.
set_up_sftp_jail() {
  if ! getent group "$SFTP_GROUP" > /dev/null; then
    run groupadd "$SFTP_GROUP"
  fi

  if sftp_jail_configured; then
    return
  fi

  echo "Setting up the SSH jail for the $SFTP_GROUP group (first time only)."

  write_file "$SFTP_SSHD_CONFIG" <<EOF
# SFTP jail for website users (managed by sitectl).
# Members of the $SFTP_GROUP group can only use SFTP, locked into their
# home folder, and can only log in with the keys in /etc/ssh/sftp-keys/<user>.
Match Group $SFTP_GROUP
    ChrootDirectory %h
    # -u 0027: uploads are readable by the site's group (which includes
    # nginx) and by nobody else.
    ForceCommand internal-sftp -u 0027
    AuthorizedKeysFile /etc/ssh/sftp-keys/%u
    PasswordAuthentication no
    AllowTcpForwarding no
    AllowAgentForwarding no
    PermitTunnel no
    X11Forwarding no
EOF

  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "  [test] sshd -t  (if it fails: move the new file to the backup folder and stop)"
    run systemctl try-reload-or-restart ssh
    return
  fi

  # Test the SSH config before reloading. A broken config could lock you
  # out of the server, so back out straight away if it fails.
  if ! sshd -t; then
    back_up "$SFTP_SSHD_CONFIG"
    die "SSH config test failed, so the SFTP jail wasn't added. Your SSH setup is unchanged."
  fi
  systemctl try-reload-or-restart ssh
}

# Ask sshd which settings it really applies to this user, and confirm the
# jail is active. Sets SFTP_KEYS_FILE to where this user's keys are read.
verify_sftp_jail() {
  local settings chroot force keys_file

  settings=$(sshd -T -C "user=$SITE_USER,host=localhost,addr=127.0.0.1" 2> /dev/null) \
    || die "couldn't read sshd's settings for $SITE_USER"

  chroot=$(awk '$1 == "chrootdirectory" { print $2 }' <<< "$settings")
  force=$(awk '$1 == "forcecommand" { print $2 }' <<< "$settings")

  if [[ -z "$chroot" || "$chroot" == "none" || "$force" != "internal-sftp" ]]; then
    # Better no SFTP than unjailed SFTP.
    run gpasswd -d "$SITE_USER" "$SFTP_GROUP" > /dev/null
    die "SSH isn't jailing $SFTP_GROUP members (chroot: ${chroot:-none}, command:" \
        "${force:-none}); another setting may take priority. Removed $SITE_USER" \
        "from $SFTP_GROUP so it can't log in unjailed."
  fi

  # The first key file listed, with %h, %u and %U filled in. A relative
  # path is relative to the home folder.
  keys_file=$(awk '$1 == "authorizedkeysfile" { print $2 }' <<< "$settings")
  keys_file="${keys_file//%h/$HOME_DIR}"
  keys_file="${keys_file//%u/$SITE_USER}"
  keys_file="${keys_file//%U/$(id -u "$SITE_USER")}"
  if [[ "$keys_file" != /* ]]; then
    keys_file="$HOME_DIR/$keys_file"
  fi
  SFTP_KEYS_FILE="$keys_file"
}

# Make sure the keys file exists, and add the public key if one was given.
install_sftp_key() {
  local keys_dir owner dir_mode file_mode
  keys_dir=$(dirname "$SFTP_KEYS_FILE")

  # Keys inside the home folder belong to the user (SSH requires that);
  # anywhere else they belong to root, so they can't be changed over SFTP.
  #
  # Keys inside the home folder (only with an SSH setup made by hand) are
  # in a folder the site user can change, so they're written as that
  # user. Root writing there could be tricked by a symlink into adding
  # the key to some other file on the server.
  local as_user=()
  if [[ "$SFTP_KEYS_FILE" == "$HOME_DIR"/* ]]; then
    owner="$SITE_USER"; dir_mode=700; file_mode=600
    as_user=(runuser -u "$SITE_USER" --)
  else
    owner="root"; dir_mode=755; file_mode=644
  fi

  if [[ -L "$keys_dir" || -L "$SFTP_KEYS_FILE" ]]; then
    die "$SFTP_KEYS_FILE (or its folder) is a symlink; refusing to write keys through it"
  fi

  if [[ ! -d "$keys_dir" ]]; then
    if [[ "$owner" == "root" ]]; then
      run install -d -o root -g root -m "$dir_mode" "$keys_dir"
    else
      # The folder sits in the root-owned home, so root creates it.
      run install -d -o "$owner" -g "$owner" -m "$dir_mode" "$keys_dir"
    fi
  fi
  if [[ ! -f "$SFTP_KEYS_FILE" ]]; then
    if [[ "$owner" == "root" ]]; then
      run install -o root -g root -m "$file_mode" /dev/null "$SFTP_KEYS_FILE"
    else
      # shellcheck disable=SC2016  # $1 is expanded by the inner sh
      run "${as_user[@]}" sh -c 'umask 077 && touch "$1"' sh "$SFTP_KEYS_FILE"
    fi
  fi

  if [[ -z "$SFTP_KEY_LINE" ]]; then
    if [[ ! -s "$SFTP_KEYS_FILE" ]]; then
      SFTP_KEY_STATUS="no key yet; add one with --sftp-key"
    else
      SFTP_KEY_STATUS="existing keys kept"
    fi
  elif [[ -f "$SFTP_KEYS_FILE" ]] && grep -qxF "$SFTP_KEY_LINE" "$SFTP_KEYS_FILE"; then
    SFTP_KEY_STATUS="key was already allowed"
  else
    if [[ "$DRY_RUN" == "yes" ]]; then
      echo "  [test] would add the key to $SFTP_KEYS_FILE"
    else
      printf '%s\n' "$SFTP_KEY_LINE" | "${as_user[@]}" tee -a "$SFTP_KEYS_FILE" > /dev/null
    fi
    SFTP_KEY_STATUS="key added"
  fi
}

set_up_sftp() {

  step "Setting up SFTP for $SITE_USER"

  set_up_sftp_jail

  if ! id -nG "$SITE_USER" 2> /dev/null | grep -qw "$SFTP_GROUP"; then
    run usermod -aG "$SFTP_GROUP" "$SITE_USER"
  fi

  # SSH only jails into a folder owned by root and not writable by group
  # or others. Homes made by this script are like that; warn if not.
  if [[ -d "$HOME_DIR" ]]; then
    local owner mode
    read -r owner mode < <(stat -c '%U %a' "$HOME_DIR")
    if [[ "$owner" != "root" || $(( 8#$mode & 8#022 )) -ne 0 ]]; then
      warn "$HOME_DIR must be owned by root and not group/other writable for the SFTP jail" \
           "(it's $owner, mode $mode). SFTP logins will fail until that's fixed."
    fi
  fi

  # Ask sshd whether the user is really jailed. In test mode that's only
  # possible if the user is already in the group (and we're root).
  if [[ "$DRY_RUN" != "yes" ]] ||
     { [[ $EUID -eq 0 ]] && id -nG "$SITE_USER" 2> /dev/null | grep -qw "$SFTP_GROUP"; }; then
    verify_sftp_jail
  else
    echo "  [test] sshd -T: check $SITE_USER really is jailed (if not: undo and stop)"
    SFTP_KEYS_FILE="/etc/ssh/sftp-keys/$SITE_USER"
  fi

  install_sftp_key
}


# -----------------------------------------------------------------------------
#  Helpers
# -----------------------------------------------------------------------------

# Returns success if --sftp or --sftp-key was given to `sitectl add`.
sftp_wanted() {
  [[ -n "${MODULE_OPTIONS[--sftp]:-}${MODULE_OPTIONS[--sftp-key]:-}${MODULE_OPTIONS[--sftpkey]:-}" ]]
}

# Returns success if a user can log in by SFTP (is in the sftponly group).
user_has_sftp() {
  id -nG "$1" 2> /dev/null | grep -qw "$SFTP_GROUP"
}

# Print where SSH reads this user's keys from, without changing anything.
# Asking sshd needs root; otherwise assume sitectl's own location.
sftp_find_keys_file() {
  local keys_file=""
  if [[ $EUID -eq 0 ]] && user_has_sftp "$SITE_USER"; then
    keys_file=$(sshd -T -C "user=$SITE_USER,host=localhost,addr=127.0.0.1" 2> /dev/null |
                awk '$1 == "authorizedkeysfile" { print $2 }')
    keys_file="${keys_file//%h/$HOME_DIR}"
    keys_file="${keys_file//%u/$SITE_USER}"
    keys_file="${keys_file//%U/$(id -u "$SITE_USER")}"
    [[ -z "$keys_file" || "$keys_file" == /* ]] || keys_file="$HOME_DIR/$keys_file"
  fi
  echo "${keys_file:-/etc/ssh/sftp-keys/$SITE_USER}"
}

# Print each allowed key as "fingerprint  comment".
sftp_list_keys() {
  local file="$1" line
  [[ -r "$file" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    ssh-keygen -l -f /dev/stdin <<< "$line" 2> /dev/null |
      awk '{ c = ""; for (i = 3; i < NF; i++) c = c (c ? " " : "") $i; print $2 "  " (c ? c : "(no comment)") }'
  done < "$file"
}


# -----------------------------------------------------------------------------
#  The module interface
# -----------------------------------------------------------------------------

# No settings yet: SFTP is set up per site, with the options and commands.
module_sftp_settings() { :; }

module_sftp_options() {
  cat <<'OPTIONS'
--sftp||Allow SFTP uploads as the site user, jailed to its home folder
--sftp-key|KEY|Public key allowed to log in: a .pub file, or the key in quotes (implies --sftp)
--sftpkey|KEY|Same as --sftp-key
OPTIONS
}

# Redeploy plan: say what SFTP will do.
module_sftp_site_preview() {
  sftp_wanted || return 0
  echo "  - allow SFTP logins as $SITE_USER, jailed to $HOME_DIR"
  if ! getent group "$SFTP_GROUP" > /dev/null || ! sftp_jail_configured; then
    echo "    (first time: also sets up the $SFTP_GROUP group and SSH jail rules)"
  fi
  local others
  others=$(other_domains_for_user "$SITE_USER")
  if [[ -n "$others" ]]; then
    echo "    The same login also reaches the folders of:$others"
  fi
}

# Before anything changes: check the key, or ask for one.
module_sftp_site_preparing() {
  prepare_sftp
}

module_sftp_site_added() {
  sftp_wanted || return 0
  set_up_sftp
}

module_sftp_site_summary() {
  if ! user_has_sftp "$SITE_USER" && ! { sftp_wanted && [[ "$DRY_RUN" == "yes" ]]; }; then
    return 0
  fi

  # Where to connect. With Cloudflare proxying, the domain points at
  # Cloudflare, which doesn't pass SSH through, so use the server's IP.
  local server_ip keys_file key_count others
  server_ip=$(hostname -I 2> /dev/null | awk '{ print $1 }')
  keys_file=$(sftp_find_keys_file)
  key_count=$(sftp_list_keys "$keys_file" | wc -l)

  echo
  echo "  SFTP:       sftp $SITE_USER@${server_ip:-<server IP>}"
  echo "              (use the server's IP: a Cloudflare-proxied domain won't pass SSH)"
  if (( key_count == 0 )); then
    echo "  SFTP keys:  $keys_file (none yet: sudo sitectl sftp add-key $DOMAIN <key>)"
  else
    echo "  SFTP keys:  $keys_file ($key_count allowed: sitectl sftp status $DOMAIN)"
  fi
  if [[ "$WEB_ROOT" == "$HOME_DIR"/* ]]; then
    echo "  Upload to:  /${WEB_ROOT#"$HOME_DIR"/}  (inside the SFTP login; private files go in /private)"
  else
    echo "  Note:       SFTP is jailed to $HOME_DIR, so it can't reach $WEB_ROOT"
  fi
  others=$(other_domains_for_user "$SITE_USER")
  if [[ -n "$others" ]]; then
    echo "  Same login: also reaches the folders of:$others"
  fi
}

module_sftp_site_removed() {
  if user_has_sftp "$SITE_USER"; then
    echo "  $SITE_USER can still log in by SFTP (the user and files are kept)."
    echo "  To stop that: sudo sitectl sftp disable <one of its other domains>, or"
    echo "                sudo gpasswd -d $SITE_USER $SFTP_GROUP"
  fi
}

module_sftp_site_info() {
  local user="$2"
  user_has_sftp "$user" && echo yes || echo no
}


# -----------------------------------------------------------------------------
#  Commands: sitectl sftp ...
# -----------------------------------------------------------------------------

# The commands: name|level|scope|usage|description (see lib/commands.sh).
# sitectl checks the arguments and access level, and takes the lock and
# logs the change, before module_sftp_command is called.
module_sftp_commands() {
  cat <<'EOF'
status|read|site?|[<domain>]|SFTP logins and their keys
enable|server-change|site|<domain> [<key>]|Allow SFTP for the site's user
add-key|site-change|site|<domain> <key>|Allow a key (.pub file, or the key in quotes)
remove-key|site-change|site|<domain> <which>|Remove a key, by fingerprint (SHA256:...), comment, or the whole key
disable|server-change|site|<domain>|Stop SFTP for the site's user (keys kept)
EOF
}

module_sftp_command() {
  local action="$1"
  shift
  case "$action" in
    status)     sftp_status "$@" ;;
    enable)     sftp_enable "$@" ;;
    add-key)    sftp_add_key "$@" ;;
    remove-key) sftp_remove_key "$@" ;;
    disable)    sftp_disable "$1" ;;
  esac
}

sftp_status() {
  if [[ $# -eq 1 ]]; then
    load_site "$1"
    echo "$DOMAIN (user $SITE_USER): SFTP $(user_has_sftp "$SITE_USER" && echo on || echo off)"
    if user_has_sftp "$SITE_USER"; then
      local keys_file
      keys_file=$(sftp_find_keys_file)
      echo "  Keys in $keys_file:"
      sftp_list_keys "$keys_file" | sed 's/^/    /'
      [[ -n "$(sftp_list_keys "$keys_file")" ]] || echo "    (none)"
    fi
    return
  fi

  # Every site user with SFTP: how many keys, and the domains it reaches.
  local config user users="" keys_file domains
  while read -r config; do
    [[ -n "$config" ]] || continue
    user=$(site_user_from_config "$config")
    [[ " $users " == *" $user "* ]] || users+=" $user"
  done < <(site_config_files)

  local rows=""
  for user in $users; do
    user_has_sftp "$user" || continue
    SITE_USER="$user" HOME_DIR="/home/$user" NGINX_CONFIG=""
    keys_file=$(sftp_find_keys_file)
    domains=$(other_domains_for_user "$user")     # every domain, as none is excluded
    rows+="$user"$'\t'"$(sftp_list_keys "$keys_file" | wc -l)"$'\t'"${domains# }"$'\n'
  done

  if [[ -z "$rows" ]]; then
    echo "No site users have SFTP. Allow it with: sudo sitectl sftp enable <domain> <key>"
    return
  fi
  printf 'USER\tKEYS\tDOMAINS\n%s' "$rows" | align_columns
}

sftp_enable() {
  load_site "$1"
  MODULE_OPTIONS[--sftp]="yes"
  [[ -n "${2:-}" ]] && MODULE_OPTIONS[--sftp-key]="$2"
  prepare_sftp
  set_up_sftp
  module_sftp_site_summary
}

sftp_add_key() {
  load_site "$1"
  user_has_sftp "$SITE_USER" ||
    die "$SITE_USER doesn't have SFTP yet: sudo sitectl sftp enable $DOMAIN \"<key>\""
  read_public_key "$2"
  SFTP_KEYS_FILE=$(sftp_find_keys_file)
  install_sftp_key
  [[ "$DRY_RUN" == "yes" ]] || echo "$SFTP_KEYS_FILE: $SFTP_KEY_STATUS"
}

sftp_remove_key() {
  local which="$2" line fingerprint comment keep="" removed=()
  load_site "$1"
  SFTP_KEYS_FILE=$(sftp_find_keys_file)
  [[ -f "$SFTP_KEYS_FILE" ]] || die "$SITE_USER has no keys file ($SFTP_KEYS_FILE)"
  [[ ! -L "$SFTP_KEYS_FILE" ]] || die "$SFTP_KEYS_FILE is a symlink; refusing to change it"

  # Keep every line that doesn't match; a key matches by fingerprint, by
  # its comment, or by being the whole key.
  while IFS= read -r line; do
    if [[ -n "$line" && "$line" != \#* ]]; then
      read -r _ fingerprint comment < <(ssh-keygen -l -f /dev/stdin <<< "$line" 2> /dev/null || true)
      comment="${comment% (*)}"
      if [[ "$which" == "$fingerprint" || "$which" == "$comment" || "$which" == "$line" ]]; then
        removed+=("$fingerprint  $comment")
        continue
      fi
    fi
    keep+="$line"$'\n'
  done < "$SFTP_KEYS_FILE"

  (( ${#removed[@]} > 0 )) || die "no key for $SITE_USER matches '$which' (see: sitectl sftp status $DOMAIN)"
  echo "Keys to remove from $SFTP_KEYS_FILE:"
  printf '  %s\n' "${removed[@]}"
  confirm_or_cancel "Remove ${#removed[@]} key(s)?"

  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "  [test] would rewrite $SFTP_KEYS_FILE without them"
    return
  fi
  make_backup_dir
  cp -p "$SFTP_KEYS_FILE" "$BACKUP_DIR/sftp-keys-$SITE_USER"

  # Keys inside the home folder are in a folder the site user controls,
  # so they're rewritten as that user; root-owned ones by root. Either
  # way the new file replaces the old in one step.
  if [[ "$SFTP_KEYS_FILE" == "$HOME_DIR"/* ]]; then
    # shellcheck disable=SC2016  # expanded by the inner sh, on purpose
    printf '%s' "$keep" | runuser -u "$SITE_USER" -- sh -c \
      'new=$(mktemp "$1.XXXXXX") && cat > "$new" && chmod 600 "$new" && mv "$new" "$1"' sh "$SFTP_KEYS_FILE"
  else
    local new
    new=$(mktemp "$SFTP_KEYS_FILE.XXXXXX")
    printf '%s' "$keep" > "$new"
    chmod 644 "$new"
    mv "$new" "$SFTP_KEYS_FILE"
  fi
  echo "Removed ${#removed[@]} key(s). Old file: $BACKUP_DIR/sftp-keys-$SITE_USER"
}

sftp_disable() {
  load_site "$1"
  user_has_sftp "$SITE_USER" || die "$SITE_USER doesn't have SFTP"
  local others
  others=$(other_domains_for_user "$SITE_USER")
  echo "This stops SFTP for $SITE_USER${others:+, which also serves:$others}."
  echo "Its keys are kept, so 'sitectl sftp enable $DOMAIN' turns it back on."
  confirm_or_cancel "Disable SFTP for $SITE_USER?"
  run gpasswd -d "$SITE_USER" "$SFTP_GROUP" > /dev/null
  [[ "$DRY_RUN" == "yes" ]] || echo "SFTP disabled for $SITE_USER."
}
