# shellcheck shell=bash
#
# sitectl library: The settings file and the skeleton folders.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.

# -----------------------------------------------------------------------------
#  Settings file
# -----------------------------------------------------------------------------

# Load the settings, starting from built-in defaults.
# Returns failure if there's no settings file yet.
load_config() {
  CERTBOT_EMAIL=""
  DEFAULT_PATH="public_html"
  DEFAULT_SITE_TYPE="php"
  INCLUDE_WWW="yes"
  GET_CERTIFICATE="yes"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    return 1
  fi

  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
}

save_config() {
  run mkdir -p "$CONFIG_DIR"

  # printf %q quotes each value safely for when the file is loaded again.
  {
    echo "# Settings for sitectl."
    echo "# Edit this file, or run: sudo sitectl config"
    echo
    echo "# Email for your Let's Encrypt account"
    printf 'CERTBOT_EMAIL=%q\n' "$CERTBOT_EMAIL"
    echo
    echo "# Web folder for new sites: relative to the user's home, or absolute"
    printf 'DEFAULT_PATH=%q\n' "$DEFAULT_PATH"
    echo
    echo "# Default site type: php or static"
    printf 'DEFAULT_SITE_TYPE=%q\n' "$DEFAULT_SITE_TYPE"
    echo
    echo "# Also set up www.<domain>: yes or no"
    printf 'INCLUDE_WWW=%q\n' "$INCLUDE_WWW"
    echo
    echo "# Get a Let's Encrypt certificate: yes or no"
    printf 'GET_CERTIFICATE=%q\n' "$GET_CERTIFICATE"
  } | write_file "$CONFIG_FILE"
}

# Create the default skeleton folders, without touching any that exist,
# so your own edits are never overwritten.
create_default_skeletons() {
  if [[ ! -d "$SKEL_DIR/php" ]]; then
    run mkdir -p "$SKEL_DIR/php"
    # The PHP line only shows its message if PHP actually runs; if PHP is
    # broken you'll see the raw code or a download instead. It deliberately
    # doesn't reveal the PHP version or username to visitors.
    write_file "$SKEL_DIR/php/index.php" <<'EOF'
<!doctype html>
<title>{{DOMAIN}}</title>
<h1>Hello from {{DOMAIN}}</h1>
<p><?= 'PHP is working.' ?></p>
EOF
  fi

  if [[ ! -d "$SKEL_DIR/static" ]]; then
    run mkdir -p "$SKEL_DIR/static"
    write_file "$SKEL_DIR/static/index.html" <<'EOF'
<!doctype html>
<title>{{DOMAIN}}</title>
<h1>Hello from {{DOMAIN}}</h1>
EOF
  fi
}

# Walk through each setting, showing the current value as the default.
run_config_wizard() {
  if ! can_ask; then
    die "no settings file at $CONFIG_FILE; run 'sudo sitectl config' first"
  fi

  step "Default settings ($CONFIG_FILE)"
  echo "Press Enter to keep the value in [brackets]."
  echo

  while true; do
    ask "Email for your Let's Encrypt account" CERTBOT_EMAIL "$CERTBOT_EMAIL"
    if [[ "$CERTBOT_EMAIL" == *@* ]]; then
      break
    fi
    echo "  That doesn't look like an email address."
  done

  ask "Web folder for new sites (relative to the user's home, or absolute)" \
      DEFAULT_PATH "$DEFAULT_PATH"
  ask_choice "Default site type" DEFAULT_SITE_TYPE "$DEFAULT_SITE_TYPE" php static
  ask_choice "Also set up www.<domain>" INCLUDE_WWW "$INCLUDE_WWW" yes no
  ask_choice "Get a Let's Encrypt certificate" GET_CERTIFICATE "$GET_CERTIFICATE" yes no

  echo
  save_config
  create_default_skeletons
  if [[ "$DRY_RUN" != "yes" ]]; then
    echo "Saved $CONFIG_FILE"
  fi
}
