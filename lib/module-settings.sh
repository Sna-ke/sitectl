# shellcheck shell=bash
#
# sitectl library: module settings and secrets, and `sitectl config`.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.
#
# Each module lists its settings (module_<name>_settings), one per line:
#   key|type|default|required|description
# Types: text, secret, yesno, email, number, path, choice:a/b/c.
#
#   /etc/sitectl/modules/<name>.conf   a module's settings (readable)
#   /etc/sitectl/secrets/<name>.conf   its secrets: API keys, passwords
#                                      (root only, never shown or logged)
#
# The built-in "core" module is sitectl's own settings (the ones
# `sitectl config` asks for), stored in /etc/sitectl/sitectl.conf.

module_settings_file() { echo "$CONFIG_DIR/modules/$1.conf"; }
module_secrets_file()  { echo "$CONFIG_DIR/secrets/$1.conf"; }

# --- The core module: sitectl's own settings --------------------------------

module_core_settings() {
  cat <<'EOF'
certbot_email|email||yes|Email for your Let's Encrypt account
default_path|path|public_html|no|Web folder for new sites (relative to the user's home, or absolute)
default_site_type|choice:php/static|php|no|Default site type
include_www|yesno|yes|no|Also set up www.<domain>
get_certificate|yesno|yes|no|Get a Let's Encrypt certificate
EOF
}

# core.certbot_email <-> the CERTBOT_EMAIL variable in sitectl.conf
core_variable() {
  local key="$1"
  echo "${key^^}"
}


# --- Settings: reading the schema -------------------------------------------

# The schema line for one setting, or nothing.
setting_schema() {
  local module="$1" key="$2" line
  while IFS= read -r line; do
    [[ "${line%%|*}" == "$key" ]] && { echo "$line"; return; }
  done < <("module_${module}_settings")
}

# Field N (1 key, 2 type, 3 default, 4 required, 5 description) of a schema line.
schema_field() {
  local IFS="|" fields
  read -r -a fields <<< "$1"
  echo "${fields[$(( $2 - 1 ))]:-}"
}

setting_keys() {
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo "${line%%|*}"
  done < <("module_${1}_settings")
}

is_secret() {
  [[ "$(schema_field "$(setting_schema "$1" "$2")" 2)" == "secret" ]]
}

# Split "dns.api_token" into SETTING_MODULE and SETTING_KEY, and check
# both exist.
parse_setting_name() {
  [[ "$1" == *.* ]] || die "give the setting as <module>.<setting>, e.g. core.certbot_email"
  SETTING_MODULE="${1%%.*}"
  SETTING_KEY="${1#*.}"
  require_module "$SETTING_MODULE"
  if [[ "$SETTING_KEY" != "enabled" || "$SETTING_MODULE" == "core" ]] &&
     [[ -z "$(setting_schema "$SETTING_MODULE" "$SETTING_KEY")" ]]; then
    die "module $SETTING_MODULE has no setting '$SETTING_KEY' (see: sitectl config show $SETTING_MODULE)"
  fi
}


# --- Settings: reading and writing values ------------------------------------

# A value from a key=value file (no code is run, unlike `source`).
read_value() {
  local file="$1" key="$2" line
  [[ -r "$file" ]] || return 1
  while IFS= read -r line; do
    if [[ "$line" == "$key="* ]]; then
      echo "${line#*=}"
      return 0
    fi
  done < "$file"
  return 1
}

# A module setting's value (or its default). Secrets need root to read.
module_get() {
  local module="$1" key="$2" value
  if [[ "$module" == "core" ]]; then
    load_config || true
    local variable
    variable="$(core_variable "$key")"
    echo "${!variable:-}"
    return
  fi
  if [[ "$key" == "enabled" ]]; then
    # Not set yet: the module's own default (built-in modules like sftp
    # are on unless switched off).
    read_value "$(module_settings_file "$module")" enabled || echo "${MODULE_DEFAULT_ENABLED[$module]:-no}"
    return
  fi
  if is_secret "$module" "$key"; then
    read_value "$(module_secrets_file "$module")" "$key" || true
    return
  fi
  if ! value=$(read_value "$(module_settings_file "$module")" "$key"); then
    value="$(schema_field "$(setting_schema "$module" "$key")" 3)"
  fi
  echo "$value"
}

module_is_set() {
  local module="$1" key="$2" file
  file="$(module_settings_file "$module")"
  is_secret "$module" "$key" && file="$(module_secrets_file "$module")"
  read_value "$file" "$key" > /dev/null
}

module_enabled() {
  [[ "$1" == "core" || "$(module_get "$1" enabled)" == "yes" ]]
}

# Check a value against its setting's type. Prints why it's wrong.
validate_setting() {
  local module="$1" key="$2" value="$3" type
  type="$(schema_field "$(setting_schema "$module" "$key")" 2)"
  [[ "$key" == "enabled" ]] && type="yesno"

  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "it can't contain line breaks"; return 1
  fi
  case "$type" in
    yesno)    [[ "$value" == "yes" || "$value" == "no" ]] || { echo "use yes or no"; return 1; } ;;
    email)    [[ "$value" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo "that isn't an email address"; return 1; } ;;
    number)   [[ "$value" =~ ^[0-9]+$ ]] || { echo "use a whole number"; return 1; } ;;
    path)     [[ "$value" =~ ^[A-Za-z0-9._/-]+$ && "$value" != *..* ]] || { echo "letters, digits, . _ - and / only"; return 1; } ;;
    secret)   [[ -n "$value" ]] || { echo "it can't be empty"; return 1; } ;;
    choice:*) local choices="${type#choice:}"
              [[ "/$choices/" == *"/$value/"* ]] || { echo "use one of: ${choices//\// }"; return 1; } ;;
    text|"")  ;;
    *)        echo "unknown setting type '$type' in module $module"; return 1 ;;
  esac
}

# Write key=value into a module's settings or secrets file, keeping the
# file's other lines. The old file is copied to the backup folder first,
# and the new one replaces it in one step, so it's never half-written.
write_value() {
  local file="$1" key="$2" value="$3" mode="$4"
  local dir new line
  dir="$(dirname "$file")"

  if [[ "$DRY_RUN" == "yes" ]]; then
    if [[ "$mode" == "600" ]]; then
      echo "  [test] would save $key (a secret, not shown) in $file"
    else
      echo "  [test] would set $key=$value in $file"
    fi
    return
  fi

  install -d -m "$([[ "$mode" == 600 ]] && echo 700 || echo 755)" "$dir"
  if [[ -f "$file" ]]; then
    make_backup_dir
    cp -p "$file" "$BACKUP_DIR/$(basename "$dir")-$(basename "$file")"
  fi

  new=$(mktemp "$dir/.new.XXXXXX")
  chmod "$mode" "$new"
  {
    if [[ -f "$file" ]]; then
      while IFS= read -r line; do
        [[ "$line" == "$key="* ]] || printf '%s\n' "$line"
      done < "$file"
    else
      echo "# Managed by sitectl. Change with: sudo sitectl config set <module>.<setting> ..."
    fi
    if [[ -n "$value" ]]; then
      printf '%s=%s\n' "$key" "$value"
    fi
  } > "$new"
  mv "$new" "$file"
}

# Set a module setting (after validating it).
module_set() {
  local module="$1" key="$2" value="$3" why

  if ! why=$(validate_setting "$module" "$key" "$value"); then
    die "can't set $module.$key: $why"
  fi

  if [[ "$module" == "core" ]]; then
    load_config || true
    local variable
    variable="$(core_variable "$key")"
    printf -v "$variable" '%s' "$value"
    make_backup_dir
    if [[ -f "$CONFIG_FILE" && "$DRY_RUN" != "yes" ]]; then
      cp -p "$CONFIG_FILE" "$BACKUP_DIR/"
    fi
    save_config
    return
  fi

  if is_secret "$module" "$key"; then
    write_value "$(module_secrets_file "$module")" "$key" "$value" 600
  else
    write_value "$(module_settings_file "$module")" "$key" "$value" 644
  fi
}

module_unset() {
  local module="$1" key="$2"
  if [[ "$module" == "core" ]]; then
    die "core settings can't be unset; set them to a new value instead"
  fi
  if is_secret "$module" "$key"; then
    write_value "$(module_secrets_file "$module")" "$key" "" 600
  else
    write_value "$(module_settings_file "$module")" "$key" "" 644
  fi
}


# --- Asking for settings ----------------------------------------------------

# Ask for a secret without showing it. From a terminal it's typed (hidden);
# otherwise it's read from what's piped in, e.g.
#   sudo sitectl config set-secret dns.api_token < token.txt
read_secret() {
  local prompt="$1" value=""
  if can_ask; then
    read -r -s -p "$prompt (typing is hidden): " value
    echo >&2
  else
    IFS= read -r value || true
  fi
  printf '%s' "$value"
}

# Walk through a module's settings; Enter keeps the current value.
module_wizard() {
  local module="$1" key line type default description current answer why

  if [[ "$module" == "core" ]]; then
    run_config_wizard
    return
  fi
  can_ask || die "this needs a terminal; use 'sitectl config set' for scripts"

  step "Settings for $module: ${MODULE_DESC[$module]}"
  echo "Press Enter to keep the value in [brackets]."
  echo

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="$(schema_field "$line" 1)"
    type="$(schema_field "$line" 2)"
    default="$(schema_field "$line" 3)"
    description="$(schema_field "$line" 5)"

    while true; do
      if [[ "$type" == "secret" ]]; then
        if module_is_set "$module" "$key"; then
          echo "$description: currently set. Press Enter to keep it."
        else
          echo "$description:"
        fi
        answer="$(read_secret "  $key" < /dev/tty)"
        [[ -z "$answer" ]] && module_is_set "$module" "$key" && break
      else
        current="$(module_get "$module" "$key")"
        ask "$description" answer "${current:-$default}" < /dev/tty
      fi
      if why=$(validate_setting "$module" "$key" "$answer"); then
        module_set "$module" "$key" "$answer"
        break
      fi
      echo "  $why"
    done
  done < <("module_${module}_settings")
}


# --- Commands: sitectl config ... -------------------------------------------

show_module_settings() {
  local module="$1" line key type value shown
  echo "$module$([[ "$module" != core ]] && echo " ($(module_enabled "$module" && echo enabled || echo disabled))")"
  [[ -n "$(setting_keys "$module")" ]] || echo "  (no settings)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="$(schema_field "$line" 1)"
    type="$(schema_field "$line" 2)"
    if [[ "$type" == "secret" ]]; then
      # The secrets folder is root-only, so without sudo there's no way to
      # tell whether a secret is set: say so, rather than guess "not set".
      local secrets_dir
      secrets_dir="$(dirname "$(module_secrets_file "$module")")"
      if [[ -d "$secrets_dir" && ! -x "$secrets_dir" ]] ||
         [[ -e "$(module_secrets_file "$module")" && ! -r "$(module_secrets_file "$module")" ]]; then
        shown="(secret: run with sudo to see if it's set)"
      elif module_is_set "$module" "$key"; then
        shown="(secret: set)"
      else
        shown="(secret: not set)"
      fi
    else
      value="$(module_get "$module" "$key")"
      shown="${value:-(not set)}"
      if [[ "$module" != core ]] && ! module_is_set "$module" "$key" && [[ -n "$value" ]]; then
        shown+="  (default)"
      fi
    fi
    printf '  %-20s %s\n' "$key" "$shown"
  done < <("module_${module}_settings")
}

cmd_config() {
  local action="${1:-}"
  shift || true

  case "$action" in
    "")
      begin_change
      load_config || true
      run_config_wizard
      ;;
    show)
      if [[ -n "${1:-}" ]]; then
        require_module "$1"
        show_module_settings "$1"
      else
        local module
        for module in "${MODULES[@]}"; do
          show_module_settings "$module"
          echo
        done
      fi
      ;;
    get)
      [[ $# -eq 1 ]] || die "usage: sitectl config get <module>.<setting>"
      parse_setting_name "$1"
      if is_secret "$SETTING_MODULE" "$SETTING_KEY"; then
        die "$1 is a secret, so it isn't shown. ('sitectl config show $SETTING_MODULE' says whether it's set.)"
      fi
      module_get "$SETTING_MODULE" "$SETTING_KEY"
      ;;
    set)
      [[ $# -eq 2 ]] || die "usage: sitectl config set <module>.<setting> <value>"
      parse_setting_name "$1"
      if [[ "$SETTING_KEY" == "enabled" ]]; then
        die "use 'sitectl modules enable|disable $SETTING_MODULE', which checks its settings first"
      fi
      if is_secret "$SETTING_MODULE" "$SETTING_KEY"; then
        die "$1 is a secret: use 'sitectl config set-secret $1', so it doesn't end up in your shell history"
      fi
      begin_change
      module_set "$SETTING_MODULE" "$SETTING_KEY" "$2"
      [[ "$DRY_RUN" == "yes" ]] || echo "Set $1"
      ;;
    set-secret)
      [[ $# -eq 1 ]] || die "usage: sitectl config set-secret <module>.<setting>   (then type it, or pipe it in)"
      parse_setting_name "$1"
      is_secret "$SETTING_MODULE" "$SETTING_KEY" || die "$1 isn't a secret; use 'sitectl config set'"
      begin_change
      local value
      value="$(read_secret "$1")"
      module_set "$SETTING_MODULE" "$SETTING_KEY" "$value"
      [[ "$DRY_RUN" == "yes" ]] || echo "Saved $1 (only root can read it)"
      ;;
    unset)
      [[ $# -eq 1 ]] || die "usage: sitectl config unset <module>.<setting>"
      parse_setting_name "$1"
      if [[ "$SETTING_KEY" == "enabled" ]]; then
        die "use 'sitectl modules disable $SETTING_MODULE'"
      fi
      begin_change
      module_unset "$SETTING_MODULE" "$SETTING_KEY"
      [[ "$DRY_RUN" == "yes" ]] || echo "Unset $1"
      ;;
    *)
      # sitectl config <module>: walk through that module's settings.
      require_module "$action"
      begin_change
      module_wizard "$action"
      ;;
  esac
}
