# shellcheck shell=bash
#
# sitectl library: Messages, questions, and making changes (or only showing them in test mode).
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.

# -----------------------------------------------------------------------------
#  Small helpers for printing messages and asking questions
# -----------------------------------------------------------------------------

# Print an error and stop the script.
die() {
  echo "Error: $*" >&2
  trap - ERR    # a deliberate stop, so skip the "Failed at line" message
  exit 1
}

# Print a warning but keep going.
warn() {
  echo "Warning: $*" >&2
}

# Print a heading for each step so the output is easy to follow.
step() {
  echo
  echo "==> $*"
}

# Returns success if someone is at a terminal to answer questions.
can_ask() {
  [[ -t 0 ]]
}

# Ask a question and store the answer in the variable named by $2.
# Pressing Enter keeps the default.
# Usage: ask "Question" variable_name "default answer"
#
# The variables inside start with _ask_ so they can't clash with the
# caller's variable name (bash would write to the wrong one).
ask() {
  local _ask_question="$1"
  local -n _ask_result="$2"     # -n: _ask_result is another name for $2
  local _ask_default="${3:-}"

  if ! can_ask; then
    die "need an answer to '$_ask_question' but there's no terminal (see --help for flags)"
  fi

  if [[ -n "$_ask_default" ]]; then
    read -r -p "$_ask_question [$_ask_default]: " _ask_result
    _ask_result="${_ask_result:-$_ask_default}"
  else
    read -r -p "$_ask_question: " _ask_result
  fi
}

# Ask a question that has a fixed set of answers, and keep asking until
# one of them is given.
# Usage: ask_choice "Question" variable_name "default" choice1 choice2 ...
#
# The variables inside start with _ask_choice_ so they can't clash with
# the caller's variable name (bash would write to the wrong one).
ask_choice() {
  local _ask_choice_question="$1"
  local -n _ask_choice_result="$2"
  local _ask_choice_default="$3"
  shift 3
  local _ask_choice_options=("$@")
  local _ask_choice_reply _ask_choice_option

  while true; do
    ask "$_ask_choice_question (${_ask_choice_options[*]})" \
        _ask_choice_reply "$_ask_choice_default"
    for _ask_choice_option in "${_ask_choice_options[@]}"; do
      if [[ "$_ask_choice_reply" == "$_ask_choice_option" ]]; then
        # shellcheck disable=SC2034  # writes to the caller's variable
        _ask_choice_result="$_ask_choice_reply"
        return
      fi
    done
    echo "  Please answer one of: ${_ask_choice_options[*]}"
  done
}

# Ask a yes/no question before doing something big. Stops the script if
# the answer is no. --yes answers yes ahead of time, and test mode
# doesn't ask, since it changes nothing anyway.
confirm_or_cancel() {
  local question="$1"
  local answer

  if [[ "$ASSUME_YES" == "yes" ]]; then
    return
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "  [test] would ask: $question"
    return
  fi

  if ! can_ask; then
    die "'$question' needs confirming; add --yes to run unattended"
  fi

  ask_choice "$question" answer "no" yes no
  if [[ "$answer" != "yes" ]]; then
    echo "Cancelled; nothing was changed."
    exit 0
  fi
}



# -----------------------------------------------------------------------------
#  Making changes (or, in test mode, only showing them)
# -----------------------------------------------------------------------------
#
#  Every command in this script that changes the system goes through one
#  of these functions, or sits behind an explicit test-mode check
#  (the skeleton copy, the nginx test and certbot), so test mode can't
#  accidentally change anything.

# Run a command, or in test mode print it instead.
#
# Commands run without fd 9, the lock (see take_lock): a service a command
# starts would otherwise keep it, and block every later change.
run() {
  if [[ "$DRY_RUN" == "yes" ]]; then
    # Some callers change IFS; reset it so the command prints with spaces.
    local IFS=" "
    echo "  [test] $*"
  else
    "$@" 9>&-
  fi
}

# The same for services started or reloaded directly.
systemctl() {
  command systemctl "$@" 9>&-
}

# Write what's piped in to a file, or in test mode show the file's
# contents instead.
# Usage: write_file /path/to/file <<EOF ... EOF
write_file() {
  local file="$1"
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "  [test] would write $file:"
    sed 's/^/  |  /'
  else
    cat > "$file"
  fi
}

# Move a file into this run's backup folder instead of deleting it.
BACKUP_DIR=""

# Create this run's backup folder, if it doesn't exist yet.
make_backup_dir() {
  if [[ -z "$BACKUP_DIR" ]]; then
    BACKUP_DIR="$CONFIG_DIR/backups/$(date +%Y%m%d-%H%M%S)-$DOMAIN"
    run mkdir -p "$BACKUP_DIR"
  fi
}

back_up() {
  local file="$1"
  make_backup_dir
  run mv "$file" "$BACKUP_DIR/"
}

# Disable a site by removing its link in sites-enabled.
#
# This is safe: the domain was checked to contain only letters, digits,
# hyphens and dots, so this path is always a single entry in
# sites-enabled; it's only removed if it's a symlink; and unlink removes
# exactly one file and can never remove a folder. The config file the
# link points to is untouched.
disable_site_link() {
  if [[ -L "$NGINX_ENABLED_LINK" ]]; then
    run unlink "$NGINX_ENABLED_LINK"
  fi
}
