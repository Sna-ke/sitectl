# shellcheck shell=bash
#
# sitectl library: finding and loading modules, their hooks, options and
# commands.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.
#
# A module is a folder (a "package"):
#
#   <name>/
#     module.conf   name, version, description, api, requires_sitectl,
#                   depends, enabled_by_default  (key=value lines)
#     module.sh     the code: functions named module_<name>_...
#     providers/    optional: one file per backend (e.g. cloudflare.sh)
#     files/        optional: templates and other files it needs
#     CHECKSUMS     sha256 of every other file (made by `sitectl modules pack`)
#     README.md     optional
#
# Modules that ship with sitectl live in /usr/local/lib/sitectl/modules;
# installed ones (`sitectl modules install`) in /var/lib/sitectl/modules.
# If both have the same module, the newer version is used, so a module
# can be updated without a new sitectl release.
#
# The functions a module can define (only _settings is required):
#
#   module_<n>_settings      its settings, one per line (see module-settings.sh)
#   module_<n>_check         test the settings work; runs on `modules enable`
#   module_<n>_options       extra options for `sitectl add`, one per line:
#                              --flag|VALUE-NAME (empty if no value)|description
#                            given options are in MODULE_OPTIONS[--flag]
#   module_<n>_command       handles `sitectl <n> ...`; module_<n>_help
#                            prints its usage
#   module_<n>_site_preview  hooks around adding and removing sites; see
#   module_<n>_site_preparing  run_module_hooks below for when each runs
#   module_<n>_site_added
#   module_<n>_site_summary
#   module_<n>_site_removed
#   module_<n>_site_info     a short value for this module's column in
#                            `sitectl list` ($1 domain, $2 site user)
#
# Module code can use sitectl's helpers: run and write_file (which only
# show what they'd do in test mode), step, warn, die, ask, module_get,
# begin_change, and load_site <domain>.

SITECTL_MODULE_API="1"
INSTALLED_MODULES_DIR="/var/lib/sitectl/modules"

MODULES=()
declare -A MODULE_DIR=() MODULE_VERSION=() MODULE_FROM=() MODULE_DESC=() \
           MODULE_DEPENDS=() MODULE_DEFAULT_ENABLED=()
declare -A MODULE_OPTIONS=() MODULE_OPTION_OWNER=() MODULE_OPTION_TAKES_VALUE=()

module_dir() { echo "${MODULE_DIR[$1]}"; }


# --- Versions -----------------------------------------------------------------

valid_version() { [[ "$1" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; }

# Returns success if version $1 is newer than $2 (1.10.0 > 1.9.2).
version_newer() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# Returns success if version $1 is at least $2.
version_at_least() {
  [[ "$1" == "$2" ]] || version_newer "$1" "$2"
}


# --- Reading and checking a package -----------------------------------------

# Read a package's module.conf into PKG_NAME, PKG_VERSION, ... and check
# it. If it isn't usable here, returns failure with the reason in
# MANIFEST_PROBLEM. (Not run in $( ), so the PKG_ values reach the caller.)
read_manifest() {
  local dir="$1" manifest="$1/module.conf"
  MANIFEST_PROBLEM=""
  PKG_NAME="" PKG_VERSION="" PKG_DESC="" PKG_API="" PKG_REQUIRES="" PKG_DEPENDS=""
  PKG_DEFAULT_ENABLED="no"

  [[ -f "$manifest" ]] || { MANIFEST_PROBLEM="no module.conf"; return 1; }
  [[ -f "$dir/module.sh" ]] || { MANIFEST_PROBLEM="no module.sh"; return 1; }

  PKG_NAME=$(read_value "$manifest" name || true)
  PKG_VERSION=$(read_value "$manifest" version || true)
  PKG_DESC=$(read_value "$manifest" description || true)
  PKG_API=$(read_value "$manifest" api || true)
  PKG_REQUIRES=$(read_value "$manifest" requires_sitectl || true)
  PKG_DEPENDS=$(read_value "$manifest" depends || true)
  PKG_DEFAULT_ENABLED=$(read_value "$manifest" enabled_by_default || echo no)

  if [[ ! "$PKG_NAME" =~ ^[a-z][a-z0-9_]{0,31}$ || "$PKG_NAME" == "core" ]]; then
    MANIFEST_PROBLEM="name must be lowercase letters, digits and _, starting with a letter (got '$PKG_NAME')"
    return 1
  fi
  valid_version "$PKG_VERSION" || { MANIFEST_PROBLEM="version must look like 1.2.3 (got '$PKG_VERSION')"; return 1; }
  [[ -n "$PKG_DESC" ]] || { MANIFEST_PROBLEM="description is missing"; return 1; }
  if [[ "$PKG_API" != "$SITECTL_MODULE_API" ]]; then
    MANIFEST_PROBLEM="it's written for module API '$PKG_API', but this sitectl uses API $SITECTL_MODULE_API"
    return 1
  fi
  if [[ -n "$PKG_REQUIRES" ]] && ! version_at_least "$SITECTL_VERSION" "$PKG_REQUIRES"; then
    MANIFEST_PROBLEM="it needs sitectl $PKG_REQUIRES or newer (this is $SITECTL_VERSION)"
    return 1
  fi
  [[ "$PKG_DEFAULT_ENABLED" == "yes" || "$PKG_DEFAULT_ENABLED" == "no" ]] ||
    { MANIFEST_PROBLEM="enabled_by_default must be yes or no"; return 1; }
}

# Returns success if a module folder is safe to load as code: every file
# and folder in it owned by root and not writable by anyone else.
# (sitectl runs as root, so anything others could change would let them
# run code as root.)
safe_to_load() {
  [[ -z "$(find "$1" \( ! -user root -o -perm /022 \) -print -quit 2> /dev/null)" ]]
}


# --- Loading ----------------------------------------------------------------

load_modules() {
  MODULES=(core)
  MODULE_DESC[core]="sitectl's own settings: defaults for new sites, Let's Encrypt email"
  MODULE_VERSION[core]="$SITECTL_VERSION"
  MODULE_FROM[core]="built-in"
  MODULE_DEFAULT_ENABLED[core]="yes"

  local dir from name
  local -A chosen_dir=() chosen_from=()

  # Find every package, keeping the newest version of each module.
  for dir in "$SITECTL_LIB/modules"/*/ "$INSTALLED_MODULES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    dir="${dir%/}"
    from="built-in"
    [[ "$dir" == "$INSTALLED_MODULES_DIR"/* ]] && from="installed"

    if ! read_manifest "$dir"; then
      warn "skipping module in $dir: $MANIFEST_PROBLEM"
      continue
    fi
    if [[ "$PKG_NAME" != "$(basename "$dir")" ]]; then
      warn "skipping module in $dir: its folder must be named after it ($PKG_NAME)"
      continue
    fi
    if [[ -n "${chosen_dir[$PKG_NAME]:-}" ]] &&
       ! version_newer "$PKG_VERSION" "${MODULE_VERSION[$PKG_NAME]}"; then
      continue
    fi
    chosen_dir[$PKG_NAME]="$dir"
    chosen_from[$PKG_NAME]="$from"
    MODULE_VERSION[$PKG_NAME]="$PKG_VERSION"
    MODULE_DESC[$PKG_NAME]="$PKG_DESC"
    MODULE_DEPENDS[$PKG_NAME]="$PKG_DEPENDS"
    MODULE_DEFAULT_ENABLED[$PKG_NAME]="$PKG_DEFAULT_ENABLED"
  done

  # Load them, in name order.
  for name in $(printf '%s\n' "${!chosen_dir[@]}" | sort); do
    dir="${chosen_dir[$name]}"
    if ! safe_to_load "$dir"; then
      warn "skipping module $name: everything in $dir must be owned by root and not writable by others"
      continue
    fi
    # shellcheck source=/dev/null
    source "$dir/module.sh"
    if ! declare -F "module_${name}_settings" > /dev/null; then
      warn "skipping module $name: it has no module_${name}_settings function"
      continue
    fi
    # Commands must be declared (level, scope, usage), so they can be checked.
    if declare -F "module_${name}_command" > /dev/null; then
      local problem
      if ! declare -F "module_${name}_commands" > /dev/null; then
        warn "skipping module $name: it has module_${name}_command but no module_${name}_commands table"
        continue
      fi
      if ! problem=$(check_command_declarations "$name"); then
        warn "skipping module $name: $problem"
        continue
      fi
    fi
    MODULES+=("$name")
    MODULE_DIR[$name]="$dir"
    MODULE_FROM[$name]="${chosen_from[$name]}"
  done

  register_module_options
}

module_exists() {
  [[ " ${MODULES[*]} " == *" $1 "* ]]
}

require_module() {
  module_exists "$1" || die "no module called '$1' (see: sitectl modules)"
}

module_has() {
  declare -F "module_${1}_$2" > /dev/null
}


# --- Options for `sitectl add` ----------------------------------------------

# Collect the options enabled modules add to `sitectl add`, so the
# command line can accept them. Their values end up in MODULE_OPTIONS.
register_module_options() {
  local module line flag value_name
  for module in "${MODULES[@]}"; do
    [[ "$module" != core ]] || continue
    module_has "$module" options || continue
    module_enabled "$module" || continue
    while IFS='|' read -r flag value_name _; do
      [[ "$flag" == --* ]] || continue
      MODULE_OPTION_OWNER[$flag]="$module"
      MODULE_OPTION_TAKES_VALUE[$flag]="$([[ -n "$value_name" ]] && echo yes || echo no)"
    done < <("module_${module}_options")
  done
}

# Help text for the module options.
module_options_help() {
  local module flag value_name description
  for module in "${MODULES[@]}"; do
    if [[ "$module" == core ]] || ! module_has "$module" options || ! module_enabled "$module"; then continue; fi
    while IFS='|' read -r flag value_name description; do
      [[ "$flag" == --* ]] || continue
      printf '  %-22s%s\n' "$flag${value_name:+ $value_name}" "$description  [$module]"
    done < <("module_${module}_options")
  done
}


# --- Hooks ------------------------------------------------------------------

# Run each enabled module's hook for an event, in name order.
#
#   site_preview    printing what a redeploy will do (before confirming)
#   site_preparing  after questions, before anything changes: check and ask
#                   for what the module needs. Runs in sitectl itself, so a
#                   failure (die) stops the whole change safely.
#   site_added      after the site is set up
#   site_summary    adding lines to the summary at the end of `add`
#   site_removed    after `sitectl remove`
#
# site_added, site_summary and site_removed run in a subshell: a failure
# there is reported but doesn't undo the site, which is already in place.
# (So they can't pass variables on; recompute what's needed.)
run_module_hooks() {
  local event="$1" module hook status
  for module in "${MODULES[@]}"; do
    [[ "$module" != core ]] || continue
    module_enabled "$module" || continue
    hook="module_${module}_${event}"
    declare -F "$hook" > /dev/null || continue

    case "$event" in
      site_preview|site_preparing)
        "$hook"
        ;;
      *)
        # In a subshell with -e, so a hook stops at its first error; its
        # status is read without letting that error stop sitectl.
        set +e
        ( set -e; "$hook" )
        status=$?
        set -e
        if (( status != 0 )); then
          warn "module $module's ${event//_/ } step failed (exit $status); the site itself is fine"
        fi
        ;;
    esac
  done
}

# Modules that add a column to `sitectl list`.
modules_with_site_info() {
  local module
  for module in "${MODULES[@]}"; do
    [[ "$module" != core ]] && module_enabled "$module" && module_has "$module" site_info &&
      echo "$module"
  done
}


# --- Commands: sitectl <module> ... -----------------------------------------
# (The dispatcher, run_module_command, is in commands.sh.)

# Returns success if `sitectl <word>` is a module's command.
is_module_command() {
  module_exists "$1" && [[ "$1" != core ]] && module_has "$1" command
}
