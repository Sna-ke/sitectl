#!/usr/bin/env bash
#
# uninstall.sh: remove the sitectl command from this server.
#
#   sudo ./uninstall.sh
#
# Removes only the files install.sh put in place: the command and its
# library folder. Your sites keep running exactly as they are, and your
# settings (/etc/sitectl), backups and the change log stay, so
# reinstalling picks up where you left off.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Error: run this with sudo" >&2; exit 1; }

LIB="/usr/local/lib/sitectl"

if [[ -f /usr/local/sbin/sitectl ]]; then
  unlink /usr/local/sbin/sitectl
  echo "Removed /usr/local/sbin/sitectl"
fi

if [[ -d "$LIB" ]]; then
  # The library files and bundled module folders sitectl ships are moved to
  # the backups (not deleted). Anything else in $LIB is left alone.
  BACKUP_DIR="/etc/sitectl/backups/$(date +%Y%m%d-%H%M%S)-uninstall"
  install -d -m 700 "$BACKUP_DIR"
  for file in "$LIB"/*.sh; do
    [[ -f "$file" && ! -L "$file" ]] && mv "$file" "$BACKUP_DIR/"
  done
  for folder in "$LIB"/modules/*/ "$LIB"/module-template/; do
    folder="${folder%/}"
    [[ -d "$folder" && ! -L "$folder" && -f "$folder/module.conf" ]] &&
      mv "$folder" "$BACKUP_DIR/"
  done
  rmdir "$LIB/modules" 2> /dev/null || true
  rmdir "$BACKUP_DIR" 2> /dev/null || echo "Moved the library files to $BACKUP_DIR/"
  rmdir "$LIB" 2> /dev/null && echo "Removed $LIB/" ||
    echo "Left $LIB/ in place: it has files sitectl didn't put there"
fi

echo "Your sites, /etc/sitectl (settings, secrets, backups), modules you"
echo "installed (/var/lib/sitectl/modules) and /var/log/sitectl.log are untouched."
