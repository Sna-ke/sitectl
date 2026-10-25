# shellcheck shell=bash
#
# sitectl library: The nginx site config.
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.

# -----------------------------------------------------------------------------
#  Step 6: Create and enable the nginx config
# -----------------------------------------------------------------------------

create_nginx_config() {
  step "Creating nginx config"

  # Only PHP sites get a block that sends .php files to the PHP pool.
  local php_section index_files

  # Listen on IPv6 too, if this server has it. (nginx refuses to start a
  # site that asks for IPv6 on a server where it's switched off.)
  local listen_v6=""
  if [[ -f /proc/net/if_inet6 ]]; then
    listen_v6=$'\n    listen [::]:80;'
  fi
  if [[ "$SITE_TYPE" == "php" ]]; then
    index_files="index.php index.html"
    php_section="
    # Send .php files to this user's PHP pool.
    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/$SITE_USER.sock;
    }"
  else
    # Static sites don't run PHP. Without this, nginx would send any .php
    # file to visitors as plain text, showing its source code (and any
    # passwords in it).
    index_files="index.html"
    php_section="
    # Static site: never send .php files' source code to visitors.
    location ~ \\.php\$ {
        return 404;
    }"
  fi

  # Note: \$uri is escaped so bash leaves it alone; it's an nginx variable.
  write_file "$NGINX_CONFIG" <<EOF
# nginx config for $DOMAIN ($CONFIG_MARKER)
# Site user: $SITE_USER

server {
    listen 80;$listen_v6
    server_name $SERVER_NAMES;

    root $WEB_ROOT;
    index $index_files;

    access_log /var/log/nginx/$DOMAIN.access.log;
    error_log  /var/log/nginx/$DOMAIN.error.log;

    # Block hidden files like .git and .env, but allow .well-known,
    # which Let's Encrypt uses.
    location ~ /\\.(?!well-known) {
        deny all;
    }

    # Serve the file if it exists, otherwise return 404.
    location / {
        try_files \$uri \$uri/ =404;
    }
$php_section
}
EOF

  # Enable the site.
  run ln -s "$NGINX_CONFIG" "$NGINX_ENABLED_LINK"

  # A new user means www-data joined a new group, and nginx only picks
  # that up on a full restart. Otherwise a reload is enough.
  local restart_type="reload"
  if [[ "$NEW_USER" == "yes" ]]; then
    restart_type="restart"
  fi

  # The new config can't be tested in test mode, since it isn't written.
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "  [test] nginx -t  (if it fails: disable the site again and stop)"
    echo "  [test] systemctl $restart_type nginx"
    return
  fi

  # Test the full nginx config. If it fails, disable the new site again
  # so nginx keeps running fine for the other sites.
  if ! nginx -t; then
    disable_site_link
    if [[ "$REDEPLOY" == "yes" ]]; then
      die "nginx config test failed with the new config."
    fi
    die "nginx config test failed; the site is disabled. Fix $NGINX_CONFIG and re-enable it."
  fi

  systemctl "$restart_type" nginx
}
