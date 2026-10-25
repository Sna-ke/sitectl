# shellcheck shell=bash
#
# The __NAME__ module for sitectl.
#
# Every function is named module___NAME___<what>. Only _settings is
# required; delete the ones you don't need. sitectl's helpers are
# available: run and write_file (they only show what they'd do in test
# mode, -t), step, warn, die, ask, module_get, load_site. The full
# guide is docs/MODULES.md in the sitectl project.
#
# To try it:
#   sitectl modules pack __NAME__.pkg
#   sudo sitectl modules install __NAME__-1.0.0.tar.gz
#   sudo sitectl config __NAME__
#   sudo sitectl modules enable __NAME__


# Settings, one per line:  key|type|default|required|description
# Types: text, secret, yesno, email, number, path, choice:a/b/c.
# Secrets (API keys, passwords) are stored where only root can read them,
# and are never shown or logged. Read any setting with:
#   module_get __NAME__ <key>
module___NAME___settings() {
  cat <<'EOF'
greeting|text|Hello|no|What to say when a site is added
api_token|secret||yes|An API token (stored where only root can read it)
EOF
}

# Optional: check the settings work (e.g. that the API token is valid).
# Runs on `sitectl modules enable`; if it returns non-zero, the module
# isn't enabled.
module___NAME___check() {
  [[ -n "$(module_get __NAME__ api_token)" ]] || { echo "  api_token isn't set"; return 1; }
  echo "  Settings look fine."
}

# Optional: extra options for `sitectl add`, one per line:
#   --flag|VALUE-NAME (empty for a yes/no switch)|description
# Given options are in MODULE_OPTIONS[--flag].
module___NAME___options() {
  cat <<'EOF'
--__NAME__-note|TEXT|A note to print when the site is added
EOF
}

# Optional hooks around adding and removing sites. DOMAIN, SITE_USER,
# HOME_DIR, WEB_ROOT and SITE_TYPE are set.
#
#   site_preview    print lines for the "Redeploying will:" list
#   site_preparing  before anything changes: check and ask for what you
#                   need; a die here stops the whole change safely
#   site_added      after the site is set up
#   site_summary    print lines for the summary at the end
#   site_removed    after `sitectl remove`
#
# site_added, site_summary and site_removed run separately, so they
# can't pass variables to each other; work out what you need each time.
# A failure in them is reported but never undoes the site.
module___NAME___site_added() {
  echo "  $(module_get __NAME__ greeting), $DOMAIN (user $SITE_USER)"
  if [[ -n "${MODULE_OPTIONS[--__NAME__-note]:-}" ]]; then
    echo "  Note: ${MODULE_OPTIONS[--__NAME__-note]}"
  fi
}

module___NAME___site_removed() {
  echo "  Goodbye, $DOMAIN"
}

# Optional: a column in `sitectl list` ($1 domain, $2 site user).
module___NAME___site_info() {
  echo "ok"
}

# Optional: your own commands, as `sitectl __NAME__ <command> ...`.
#
# Declare each one: name|level|scope|usage|description
#   level  read, read-root, site-change, server-change or server-admin
#          (lowest to highest; see "Access levels" in docs/MODULES.md)
#   scope  server; site (the first argument is a domain); or site? (a
#          domain is optional, and without one it covers every site)
#   usage  <required> [<optional>] and a trailing ... for any number more
# Pick the lowest level that's true: it decides who can be allowed to
# run it (e.g. from a web panel), and whether sudo is needed.
#
# Before module___NAME___command runs, sitectl has already checked the
# argument count, the domain (for site scope) and the access level, and
# for a change taken the lock and started the change-log entry. Help
# (`sitectl __NAME__ help`) is made from this table.
module___NAME___commands() {
  cat <<'EOF'
hello|read|site|<domain>|Say hello to a site
EOF
}

# $1 is the command name (one from the table above), then its arguments.
module___NAME___command() {
  local action="$1"
  shift
  case "$action" in
    hello)
      load_site "$1"
      echo "$(module_get __NAME__ greeting), $DOMAIN! (user $SITE_USER, files in $WEB_ROOT)"
      ;;
  esac
}
