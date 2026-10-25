#!/usr/bin/env bash
#
# install.sh: install (or upgrade) sitectl on this server.
#
#   sudo ./install.sh
#
# Puts the command in /usr/local/sbin/sitectl and its library files in
# /usr/local/lib/sitectl. Running it again upgrades in place. Your
# settings (/etc/sitectl) and your sites are never touched, except that
# settings from the older add-new-site script are moved over once.

set -euo pipefail

die() { echo "Error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run this with sudo: sudo ./install.sh"

SOURCE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
[[ -f "$SOURCE/bin/sitectl" && -d "$SOURCE/lib" ]] ||
  die "run this from the unpacked sitectl folder (it needs bin/ and lib/ next to it)"

BIN="/usr/local/sbin/sitectl"
LIB="/usr/local/lib/sitectl"
OLD_CONFIG="/etc/add-new-site"
NEW_CONFIG="/etc/sitectl"

# Move settings over from the older add-new-site script, once. (Moved,
# not copied, so there's one place to edit; nothing is deleted.)
if [[ -d "$OLD_CONFIG" && ! -e "$NEW_CONFIG" ]]; then
  echo "==> Moving settings from $OLD_CONFIG to $NEW_CONFIG"
  mv "$OLD_CONFIG" "$NEW_CONFIG"
  if [[ -f "$NEW_CONFIG/add-new-site.conf" ]]; then
    mv "$NEW_CONFIG/add-new-site.conf" "$NEW_CONFIG/sitectl.conf"
    sed -i 's/add-new-site --config/sitectl config/; s/Settings for add-new-site/Settings for sitectl/' \
      "$NEW_CONFIG/sitectl.conf"
  fi
fi
install -d -m 755 "$NEW_CONFIG"

echo "==> Installing sitectl"
# Anything replaced or retired goes here rather than being deleted.
BACKUP_DIR="$NEW_CONFIG/backups/$(date +%Y%m%d-%H%M%S)-install"
retire() {
  install -d -m 700 "$BACKUP_DIR"
  mv "$1" "$BACKUP_DIR/"
}

# Copy a folder of the product (a bundled module, or the template for new
# modules) into place, retiring the older copy first so a file the new
# version no longer has doesn't linger.
install_folder() {
  local from="$1" to="$2"
  [[ -e "$to" ]] && retire "$to"
  cp -R "$from" "$to"
  chown -R root:root "$to"
  find "$to" -type d -exec chmod 755 {} +
  find "$to" -type f -exec chmod 644 {} +
}

install -d -m 755 "$LIB" "$LIB/modules"

# Library files an earlier version had that this one doesn't (in 0.3:
# sftp.sh, now the sftp module, and the old single-file module template).
for file in "$LIB"/*.sh "$LIB"/modules/*; do
  [[ -f "$file" && ! -L "$file" ]] || continue
  [[ "$file" == "$LIB"/modules/* || ! -e "$SOURCE/lib/${file##*/}" ]] || continue
  retire "$file"
  echo "  retired ${file#"$LIB"/} (it's in $BACKUP_DIR)"
done

install -m 644 "$SOURCE"/lib/*.sh "$LIB/"
install -m 755 "$SOURCE/bin/sitectl" "$BIN"
echo "  $BIN"
echo "  $LIB/"
for module in "$SOURCE"/lib/modules/*/; do
  module="${module%/}"
  install_folder "$module" "$LIB/modules/${module##*/}"
  echo "  $LIB/modules/${module##*/}/ (version $(sed -n 's/^version=//p' "$module/module.conf"))"
done
install_folder "$SOURCE/lib/module-template" "$LIB/module-template"

# Modules you install with `sitectl modules install` go here.
install -d -m 755 /var/lib/sitectl /var/lib/sitectl/modules

# 0.2 loaded single-file modules from modules.d. They're no longer read.
if compgen -G "$NEW_CONFIG/modules.d/*.sh" > /dev/null; then
  echo "  Note: $NEW_CONFIG/modules.d/ has modules in the old single-file format,"
  echo "        which this version doesn't load. Make each a package with"
  echo "        'sitectl modules new <name>', move the code in, then install it."
fi

# What sitectl needs. Missing ones are listed, not installed, so nothing
# on the server changes without you choosing it.
echo "==> Checking what sitectl needs"
missing=()
for command in nginx certbot curl openssl runuser flock; do
  command -v "$command" > /dev/null || missing+=("$command")
done
if ! ls /etc/php/*/fpm/pool.d > /dev/null 2>&1; then
  echo "  php-fpm isn't installed: only --static sites will work until it is"
fi
if [[ -x /usr/bin/certbot ]] && ! /usr/bin/certbot plugins 2> /dev/null | grep -q nginx; then
  missing+=("certbot's nginx plugin")
fi
if (( ${#missing[@]} > 0 )); then
  echo "  Missing: ${missing[*]}"
  echo "  Install with: sudo apt install nginx certbot python3-certbot-nginx curl openssl util-linux"
else
  echo "  All there."
fi

# certbot's renewal timer keeps certificates up to date.
if systemctl list-unit-files certbot.timer > /dev/null 2>&1; then
  if ! systemctl is-enabled certbot.timer > /dev/null 2>&1; then
    echo "  Note: certbot's renewal timer is off. Turn it on with:"
    echo "        sudo systemctl enable --now certbot.timer"
  fi
fi

if [[ -e /usr/local/sbin/add-new-site ]]; then
  echo
  echo "The older add-new-site command is still at /usr/local/sbin/add-new-site."
  echo "sitectl replaces it and manages the sites it made. When you're ready,"
  echo "move it out of the way:  sudo mv /usr/local/sbin/add-new-site /root/"
fi

echo
echo "Done: $("$BIN" version). Try:  sitectl help   or   sitectl list"
