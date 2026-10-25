# shellcheck shell=bash
#
# sitectl library: the command table, and the privilege checks made from it.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.
#
# Every command, sitectl's own and each module's, is declared with one line:
#
#   name|level|scope|usage|description
#
# name    the command. Full names are what a caller (the future web panel,
#         via `sitectl api`) asks for: sitectl's own are "add", "list",
#         "config.set", "modules.install"; a module's are "<module>.<name>",
#         e.g. "sftp.add-key".
# level   what it needs and what it can do, lowest to highest:
#           read           only reads; works without root (may show less:
#                          `list` without sudo can't see certificate dates)
#           read-root      only reads, but needs root (e.g. root-only files)
#           site-change    changes one site and nothing else on the server
#           server-change  changes the server: users, shared config, settings
#           server-admin   can run new code as root (installing modules);
#                          never something a web panel should be allowed
# scope   server  acts on the server as a whole
#         site    the first argument is a domain, and it acts on that site
#         site?   the same when a domain is given; with none, it covers
#                 every site (so it counts as server scope)
# usage   the arguments: <required>, [<optional>], and a trailing ... for
#         "any number more". Module commands are checked against it before
#         they run.
# description  one line, for help and the panel
#
# A panel decides who may run what (Alice manages example.com); sitectl
# uses the level to require root, take the lock and log the change, and
# later (sitectl api) to cap what a caller may ever ask for.

COMMAND_LEVELS=(read read-root site-change server-change server-admin)

# The level's position in COMMAND_LEVELS (0 = read), or failure if unknown.
level_rank() {
  local i
  for i in "${!COMMAND_LEVELS[@]}"; do
    [[ "${COMMAND_LEVELS[$i]}" == "$1" ]] && { echo "$i"; return 0; }
  done
  return 1
}

# Returns success if a level changes things (and so needs the lock and log).
level_changes() {
  [[ "$1" == site-change || "$1" == server-change || "$1" == server-admin ]]
}

# sitectl's own commands. (add, add-subdomain and remove are server-change,
# not site-change: they can create or retire users and PHP pools. Finer,
# site-only versions can come later.)
core_commands() {
  cat <<'EOF'
add|server-change|site|<domain>|Add a site, or redeploy it (files are kept)
add-subdomain|server-change|site|<domain> <name>|Add <name>.<domain> to an existing site
remove|server-change|site|<domain>|Take a site down (configs to backups; user and files kept)
remove-subdomain|server-change|site|<domain> <name>|Take a subdomain down
list|read|site?|[<domain>]|Sites with user, type, certificate expiry and module columns
config|server-change|server|[<module>]|Walk through a module's settings (core if none)
config.show|read|server|[<module>]|Show settings (secrets only as set / not set)
config.get|read|server|<module.key>|Print one setting
config.set|server-change|server|<module.key> <value>|Change a setting
config.set-secret|server-change|server|<module.key>|Store a secret (typed hidden, or piped in)
config.unset|server-change|server|<module.key>|Go back to a setting's default
modules.list|read|server||Modules with version, state and where they're from
modules.info|read|server|<module>|A module's details, settings and commands
modules.enable|server-change|server|<module>|Turn a module on (checks its settings first)
modules.disable|server-change|server|<module>|Turn a module off (settings kept)
modules.install|server-admin|server|<folder or .tar.gz>|Install or upgrade a module package
modules.uninstall|server-admin|server|<module>|Remove an installed module (to the backups)
modules.pack|read|server|<folder>|Write CHECKSUMS and make <name>-<version>.tar.gz (no root needed)
modules.new|read|server|<name>|Start a module from the template, in the current folder
commands|read|server||Every command with its level and scope (--json for programs)
help|read|server||Help
version|read|server||Version
EOF
}

# Every command, as owner|full-name|level|scope|usage|description.
command_table() {
  local module name level scope usage description
  while IFS='|' read -r name level scope usage description; do
    [[ -n "$name" ]] && printf 'core|%s|%s|%s|%s|%s\n' "$name" "$level" "$scope" "$usage" "$description"
  done < <(core_commands)
  for module in "${MODULES[@]}"; do
    if [[ "$module" == core ]] || ! module_enabled "$module" || ! module_has "$module" commands; then
      continue
    fi
    while IFS='|' read -r name level scope usage description; do
      [[ -n "$name" ]] && printf '%s|%s.%s|%s|%s|%s|%s\n' \
        "$module" "$module" "$name" "$level" "$scope" "$usage" "$description"
    done < <("module_${module}_commands")
  done
}

# Look a command up by full name. Sets CMD_OWNER, CMD_NAME, CMD_LEVEL,
# CMD_SCOPE, CMD_USAGE and CMD_DESCRIPTION, or returns failure.
find_command() {
  local line
  line=$(command_table | awk -F'|' -v name="$1" '$2 == name { print; exit }')
  [[ -n "$line" ]] || return 1
  # (All six are set for callers, including the future `sitectl api`.)
  # shellcheck disable=SC2034
  IFS='|' read -r CMD_OWNER CMD_NAME CMD_LEVEL CMD_SCOPE CMD_USAGE CMD_DESCRIPTION <<< "$line"
}

# Check a module's declarations when it loads, so a mistake shows up at
# once rather than when someone runs the command. Prints the problem.
check_command_declarations() {
  local module="$1" name level scope usage description
  while IFS='|' read -r name level scope usage description; do
    [[ -n "$name" ]] || continue
    [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "command '$name': names are lowercase letters, digits and -"; return 1; }
    level_rank "$level" > /dev/null || { echo "command $name: unknown level '$level' (use one of: ${COMMAND_LEVELS[*]})"; return 1; }
    [[ "$scope" == server || "$scope" == site || "$scope" == "site?" ]] ||
      { echo "command $name: scope must be server, site or site?"; return 1; }
    [[ -n "$description" ]] || { echo "command $name: it needs a description"; return 1; }
  done < <("module_${module}_commands")
}

# The smallest and largest number of arguments a usage allows, as "MIN MAX"
# (MAX is "any" after a trailing ...).
usage_arity() {
  local word min=0 max=0
  for word in $1; do
    case "$word" in
      ...)    max="any" ;;
      \[*)    [[ "$max" == any ]] || max=$((max + 1)) ;;
      *)      min=$((min + 1)); [[ "$max" == any ]] || max=$((max + 1)) ;;
    esac
  done
  echo "$min $max"
}

# Make sure this process may run a command of the given level. A change
# in test mode (-t) needs no root, since nothing is changed.
require_level() {
  local level="$1" full_name="$2"
  case "$level" in
    read) ;;
    read-root)
      [[ $EUID -eq 0 ]] || die "sitectl ${full_name//./ } needs sudo"
      ;;
    *)
      [[ $EUID -eq 0 || "$DRY_RUN" == "yes" ]] ||
        die "sitectl ${full_name//./ } needs sudo (or add -t to see what it would do)"
      ;;
  esac
}

# The full name of the sitectl command being run (config set -> config.set),
# or nothing if it isn't one of sitectl's own. Unknown subcommands are left
# to the command itself to report.
core_command_name() {
  case "$SUBCOMMAND" in
    config)
      case "${ARGS[0]:-}" in
        show|get|set|set-secret|unset) echo "config.${ARGS[0]}" ;;
        *)                             echo "config" ;;
      esac
      ;;
    modules)
      case "${ARGS[0]:-list}" in
        list|info|enable|disable|install|uninstall|pack|new) echo "modules.${ARGS[0]:-list}" ;;
      esac
      ;;
    -h|--help) echo "help" ;;
    *)
      if core_commands | cut -d'|' -f1 | grep -qxF -- "$SUBCOMMAND"; then
        echo "$SUBCOMMAND"
      fi
      ;;
  esac
}

# Before one of sitectl's own commands runs: check this process may run it.
authorize_core_command() {
  local name
  name=$(core_command_name)
  [[ -n "$name" ]] || return 0
  find_command "$name" || return 0
  require_level "$CMD_LEVEL" "$CMD_NAME"
}

# sitectl <module> <command> [args]: look the command up in the module's
# table, check its arguments and level, take the lock and log a change,
# then hand over to the module.
run_module_command() {
  local module="$1" action="${2:-}"
  shift 2 || shift $#
  if ! module_enabled "$module"; then
    die "the $module module is disabled; enable it with: sudo sitectl modules enable $module"
  fi
  if [[ -z "$action" || "$action" == help ]]; then
    module_commands_help "$module"
    return
  fi
  find_command "$module.$action" || die "unknown $module command: $action (see: sitectl $module help)"

  local arity min max
  arity=$(usage_arity "$CMD_USAGE")
  min="${arity% *}" max="${arity#* }"
  if (( $# < min )) || { [[ "$max" != any ]] && (( $# > max )); }; then
    die "usage: sitectl $module $action $CMD_USAGE"
  fi

  require_level "$CMD_LEVEL" "$CMD_NAME"
  if [[ "$CMD_SCOPE" == site || ( "$CMD_SCOPE" == "site?" && $# -gt 0 ) ]]; then
    set_domain "$1"         # checks it's a valid domain before anything runs
  fi
  if level_changes "$CMD_LEVEL"; then
    begin_change            # root (unless -t), the lock, and the change log
  fi

  "module_${module}_command" "$action" "$@"
}

# Help lines for module commands: every enabled module's, or just one's.
module_commands_help() {
  local only="${1:-}" owner name level scope usage description shown
  while IFS='|' read -r owner name level scope usage description; do
    [[ "$owner" != core ]] || continue
    [[ -z "$only" || "$owner" == "$only" ]] || continue
    shown="sitectl ${name/./ }${usage:+ $usage}"
    if level_changes "$level" || [[ "$level" == read-root ]]; then
      shown="sudo $shown"
    fi
    printf '  %-46s%s\n' "$shown" "$description"
  done < <(command_table)
}

# sitectl commands [--json]: the whole table, for people and programs.
cmd_commands() {
  local owner name level scope usage description first="yes"
  if [[ "$LIST_FORMAT" == "json" ]]; then
    echo "["
    while IFS='|' read -r owner name level scope usage description; do
      [[ "$first" == yes ]] || echo ","
      first="no"
      printf '  {"name": %s, "module": %s, "level": %s, "scope": %s, "usage": %s, "description": %s}' \
        "$(json_string "$name")" "$(json_string "$owner")" "$(json_string "$level")" \
        "$(json_string "$scope")" "$(json_string "$usage")" "$(json_string "$description")"
    done < <(command_table)
    printf '\n]\n'
    return
  fi
  {
    printf 'COMMAND\tLEVEL\tSCOPE\tARGUMENTS\n'
    while IFS='|' read -r owner name level scope usage description; do
      printf '%s\t%s\t%s\t%s\n' "$name" "$level" "$scope" "${usage:--}"
    done < <(command_table)
  } | align_columns
}
