# shellcheck shell=bash
#
# sitectl library: the lock (one change at a time) and the change log.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.

LOCK_FILE="/run/sitectl.lock"
LOG_FILE="/var/log/sitectl.log"
LOGGED_COMMAND=""

# Only one sitectl change may run at a time: two at once could both
# rewrite the same pool, AppArmor file or SSH config. Test mode and
# read-only commands (list, help) don't take the lock.
take_lock() {
  exec 9> "$LOCK_FILE"
  if ! flock -n 9; then
    die "another sitectl change is running; try again when it's finished"
  fi
}

# Record each change in /var/log/sitectl.log: when, who (the person
# behind sudo, not just "root"), the command, and how it ended. This is
# the start of an audit trail, which a management portal will need.
#
# Public keys given with --sftp-key are shortened to their type and
# comment, so the log stays readable.
log_change_start() {
  local args=() arg next_is_key="no"
  for arg in "$@"; do
    if [[ "$next_is_key" == "yes" ]]; then
      if [[ -f "$arg" ]]; then
        args+=("$arg")
      else
        args+=("<key ${arg%% *} …${arg##* }>")
      fi
      next_is_key="no"
      continue
    fi
    [[ "$arg" == "--sftp-key" || "$arg" == "--sftpkey" ]] && next_is_key="yes"
    args+=("$arg")
  done
  LOGGED_COMMAND="sitectl ${args[*]}"
}

log_change_end() {
  local status="$1"
  [[ -n "$LOGGED_COMMAND" ]] || return 0

  local result="ok"
  if [[ "$status" -ne 0 ]]; then
    result="failed (exit $status)"
  fi

  # Create the log readable by root and the adm group (like other system
  # logs), and never let a logging problem stop the script.
  {
    if [[ ! -e "$LOG_FILE" ]]; then
      install -m 640 -o root -g adm /dev/null "$LOG_FILE"
    fi
    printf '%s  %-12s  %-6s  %s\n' "$(date -Is)" "${SUDO_USER:-$(id -un)}" \
      "${result%% *}" "$LOGGED_COMMAND" >> "$LOG_FILE"
  } 2> /dev/null || true
}
