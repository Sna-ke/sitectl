# shellcheck shell=bash
#
# sitectl library: `sitectl modules` (list, info, enable, disable,
# install, uninstall, pack, new).
# Sourced by /usr/local/sbin/sitectl; not meant to be run on its own.

# --- Checking a package before installing it -------------------------------

# Check a package folder thoroughly. Sets PKG_* from its module.conf. If
# it can't be installed, returns failure with the reason in
# PACKAGE_PROBLEM. (Not run in $( ), so PKG_* reach the caller.)
check_package() {
  local dir="$1" sum path
  PACKAGE_PROBLEM=""

  if [[ -n "$(find "$dir" \( -type l -o ! -type f ! -type d \) -print -quit)" ]]; then
    PACKAGE_PROBLEM="it contains links or special files; a package is only plain files and folders"
    return 1
  fi
  read_manifest "$dir" || { PACKAGE_PROBLEM="$MANIFEST_PROBLEM"; return 1; }
  [[ -f "$dir/CHECKSUMS" ]] || { PACKAGE_PROBLEM="it has no CHECKSUMS file (make one with: sitectl modules pack <folder>)"; return 1; }

  # Every file is listed in CHECKSUMS, and matches it.
  local -A listed=()
  while read -r sum path; do
    [[ -n "$sum" ]] || continue
    if [[ ! "$sum" =~ ^[0-9a-f]{64}$ || "$path" == /* || "$path" == *..* ]]; then
      PACKAGE_PROBLEM="CHECKSUMS has a line that isn't a plain 'sha256  relative/path' entry"
      return 1
    fi
    listed[$path]=1
  done < "$dir/CHECKSUMS"
  while IFS= read -r path; do
    path="${path#./}"
    [[ "$path" == "CHECKSUMS" ]] && continue
    [[ -n "${listed[$path]:-}" ]] || { PACKAGE_PROBLEM="$path isn't listed in CHECKSUMS"; return 1; }
  done < <(cd "$dir" && find . -type f | sort)
  if ! (cd "$dir" && sha256sum --check --strict --quiet CHECKSUMS > /dev/null 2>&1); then
    PACKAGE_PROBLEM="a file doesn't match CHECKSUMS (damaged, or changed after packing)"
    return 1
  fi

  # Modules it depends on must be here.
  local needed
  for needed in $PKG_DEPENDS; do
    module_exists "$needed" || { PACKAGE_PROBLEM="it needs the $needed module, which isn't installed"; return 1; }
  done
}

# Unpack a .tar.gz package into a new temporary folder, and set
# UNPACKED_DIR to the package folder inside it.
unpack_package() {
  local archive="$1" tmp top
  tmp=$(mktemp -d /tmp/sitectl-module.XXXXXX)
  # --no-same-owner/permissions: the files become root's, with normal
  # permissions, whatever the archive says. GNU tar also refuses paths
  # outside the folder; check_package then rejects links.
  if ! tar -xzf "$archive" -C "$tmp" --no-same-owner --no-same-permissions; then
    remove_unpacked "$tmp"
    die "couldn't unpack $archive"
  fi
  if [[ -f "$tmp/module.conf" ]]; then
    UNPACKED_DIR="$tmp"
    return
  fi
  top=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d)
  if [[ -z "$top" || $(wc -l <<< "$top") -ne 1 || ! -f "$top/module.conf" ]]; then
    remove_unpacked "$tmp"
    die "$archive doesn't contain a module package (a folder with module.conf)"
  fi
  UNPACKED_DIR="$top"
}

# Remove the temporary folder unpack_package made (on_exit calls this), and nothing else: the
# path must be exactly /tmp/sitectl-module.XXXXXX (as mktemp made it),
# or nothing is removed.
remove_unpacked() {
  local root
  root=$(cut -d/ -f1-3 <<< "$1")
  if [[ "$root" =~ ^/tmp/sitectl-module\.[A-Za-z0-9]{6}$ && -d "$root" && ! -L "$root" ]]; then
    rm -rf -- "$root"
  fi
}


# --- The commands -----------------------------------------------------------

modules_list() {
  local module state
  {
    printf 'MODULE\tVERSION\tSTATE\tFROM\tDESCRIPTION\n'
    for module in "${MODULES[@]}"; do
      if [[ "$module" == core ]]; then
        state="always on"
      elif module_enabled "$module"; then
        state="enabled"
      else
        state="disabled"
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$module" "${MODULE_VERSION[$module]}" "$state" \
        "${MODULE_FROM[$module]}" "${MODULE_DESC[$module]}"
    done
  } | align_columns

  # Mention built-in versions that are newer than the installed ones in use.
  local dir
  for dir in "$SITECTL_LIB/modules"/*/; do
    [[ -d "$dir" ]] || continue
    read_manifest "${dir%/}" || continue
    if module_exists "$PKG_NAME" && version_newer "$PKG_VERSION" "${MODULE_VERSION[$PKG_NAME]}"; then
      echo "Note: sitectl ships $PKG_NAME $PKG_VERSION, newer than the one in use."
    fi
  done
}

modules_info() {
  local module="$1"
  require_module "$module"
  echo "$module ${MODULE_VERSION[$module]}: ${MODULE_DESC[$module]}"
  if [[ "$module" == core ]]; then
    echo "  Built into sitectl."
  else
    echo "  From:        ${MODULE_FROM[$module]} ($(module_dir "$module"))"
    echo "  State:       $(module_enabled "$module" && echo enabled || echo disabled)"
    [[ -n "${MODULE_DEPENDS[$module]}" ]] && echo "  Needs:       ${MODULE_DEPENDS[$module]}"
    [[ -f "$(module_dir "$module")/README.md" ]] && echo "  Read me:     $(module_dir "$module")/README.md"
  fi
  echo
  show_module_settings "$module"
  if [[ "$module" != core ]] && module_has "$module" command; then
    echo
    echo "Commands:"
    if module_has "$module" help; then "module_${module}_help"; else echo "  sitectl $module ..."; fi
  fi
}

modules_enable() {
  local name="$1"
  require_module "$name"
  [[ "$name" != core ]] || die "core is always on"
  begin_change

  local needed
  for needed in ${MODULE_DEPENDS[$name]}; do
    module_enabled "$needed" || die "$name needs the $needed module enabled first"
  done

  # Required settings that aren't set yet: ask for them, or explain.
  local key schema missing=()
  while IFS= read -r key; do
    schema="$(setting_schema "$name" "$key")"
    if [[ "$(schema_field "$schema" 4)" == "yes" ]] && ! module_is_set "$name" "$key" &&
       [[ -z "$(schema_field "$schema" 3)" ]]; then
      missing+=("$key")
    fi
  done < <(setting_keys "$name")
  if (( ${#missing[@]} > 0 )); then
    if can_ask && [[ "$DRY_RUN" != "yes" ]]; then
      echo "$name needs some settings first."
      module_wizard "$name"
    else
      die "$name needs these settings first: ${missing[*]} (sitectl config $name)"
    fi
  fi

  # Let the module check its settings work before switching it on.
  if module_has "$name" check && [[ "$DRY_RUN" != "yes" ]]; then
    step "Checking $name's settings"
    "module_${name}_check" || die "$name's settings didn't pass its check, so it wasn't enabled"
  fi
  write_value "$(module_settings_file "$name")" enabled yes 644
  [[ "$DRY_RUN" == "yes" ]] || echo "Enabled $name."
}

modules_disable() {
  local name="$1" other
  require_module "$name"
  [[ "$name" != core ]] || die "core can't be disabled"
  for other in "${MODULES[@]}"; do
    if [[ " ${MODULE_DEPENDS[$other]:-} " == *" $name "* ]] && module_enabled "$other"; then
      die "$other needs $name; disable $other first"
    fi
  done
  begin_change
  write_value "$(module_settings_file "$name")" enabled no 644
  [[ "$DRY_RUN" == "yes" ]] || echo "Disabled $name. (Its settings are kept.)"
}

# sitectl modules install <folder | .tar.gz>
modules_install() {
  local source="$1" dir current="" what target
  [[ -e "$source" ]] || die "no such file or folder: $source"

  if [[ -f "$source" ]]; then
    [[ "$source" == *.tar.gz || "$source" == *.tgz ]] ||
      die "a module package is a folder or a .tar.gz file"
    unpack_package "$source"        # the temporary folder is removed on exit
    dir="$UNPACKED_DIR"
  else
    dir="${source%/}"
  fi

  if ! check_package "$dir"; then
    die "can't install $source: $PACKAGE_PROBLEM"
  fi

  # What this install means: new, upgrade, reinstall or downgrade.
  if module_exists "$PKG_NAME"; then
    current="${MODULE_VERSION[$PKG_NAME]}"
    if version_newer "$PKG_VERSION" "$current"; then
      what="upgrade from $current"
    elif [[ "$PKG_VERSION" == "$current" ]]; then
      what="reinstall of $current"
    else
      what="DOWNGRADE from $current"
    fi
  else
    what="new module"
  fi

  echo
  echo "Module:   $PKG_NAME $PKG_VERSION ($what)"
  echo "About:    $PKG_DESC"
  [[ -n "$PKG_DEPENDS" ]] && echo "Needs:    $PKG_DEPENDS"
  echo "Files:    $(cd "$dir" && find . -type f | wc -l), all matching CHECKSUMS"
  echo
  echo "Modules run as root, with full control of this server. Only install"
  echo "modules you trust."
  echo

  DOMAIN="module-$PKG_NAME"       # names the backup folder
  begin_change
  confirm_or_cancel "Install $PKG_NAME $PKG_VERSION?"

  target="$INSTALLED_MODULES_DIR/$PKG_NAME"
  run install -d -m 755 "$INSTALLED_MODULES_DIR"
  if [[ -d "$target" ]]; then
    back_up "$target"      # the previous installed version, for rolling back
  fi
  run cp -R "$dir" "$target"
  run chown -R root:root "$target"
  run find "$target" -type d -exec chmod 755 {} +
  run find "$target" -type f -exec chmod 644 {} +

  if [[ "$DRY_RUN" != "yes" ]]; then
    echo "Installed $PKG_NAME $PKG_VERSION in $target"
    [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" ]] && echo "  Previous version: $BACKUP_DIR"
    if [[ "$what" == "new module" && "$PKG_DEFAULT_ENABLED" != "yes" ]]; then
      echo "Next: sudo sitectl config $PKG_NAME   then   sudo sitectl modules enable $PKG_NAME"
    fi
  fi
}

# sitectl modules uninstall <name>: removes the installed copy (to the
# backup folder). Settings and secrets stay. A built-in copy, if there is
# one, is used again.
modules_uninstall() {
  local name="$1" target="$INSTALLED_MODULES_DIR/$1"
  [[ -d "$target" ]] || die "$name isn't an installed module (built-in modules can be disabled, not uninstalled)"
  DOMAIN="module-$name"
  begin_change
  confirm_or_cancel "Uninstall $name? (Its settings are kept.)"
  back_up "$target"
  if [[ "$DRY_RUN" != "yes" ]]; then
    echo "Uninstalled $name; the files are in $BACKUP_DIR."
    if [[ -d "$SITECTL_LIB/modules/$name" ]]; then
      echo "The built-in $name module is used again."
    fi
  fi
}

# sitectl modules pack <folder>: write its CHECKSUMS and make
# <name>-<version>.tar.gz in the current folder, ready to install.
modules_pack() {
  local dir="${1%/}" archive
  [[ -d "$dir" ]] || die "no such folder: $dir"
  read_manifest "$dir" || die "can't pack $dir: $MANIFEST_PROBLEM"
  if [[ -n "$(find "$dir" \( -type l -o ! -type f ! -type d \) -print -quit)" ]]; then
    die "can't pack $dir: it contains links or special files"
  fi

  # Written to a temporary file first, so CHECKSUMS never lists itself.
  local sums
  sums=$(cd "$dir" && find . -type f ! -name CHECKSUMS | sed 's|^\./||' | LC_ALL=C sort |
         xargs -d '\n' sha256sum)
  printf '%s\n' "$sums" > "$dir/CHECKSUMS"
  echo "Wrote $dir/CHECKSUMS"

  archive="$PWD/$PKG_NAME-$PKG_VERSION.tar.gz"
  tar -czf "$archive" -C "$(dirname "$(readlink -f "$dir")")" \
      --transform "s|^$(basename "$(readlink -f "$dir")")|$PKG_NAME|" \
      --owner=0 --group=0 "$(basename "$(readlink -f "$dir")")"
  echo "Made $archive"
  echo "Install it with: sudo sitectl modules install $archive"
}

# sitectl modules new <name>: start a new module from the template.
modules_new() {
  local name="$1" target="./$1.pkg" template="$SITECTL_LIB/module-template"
  [[ "$name" =~ ^[a-z][a-z0-9_]{0,31}$ && "$name" != core ]] ||
    die "module names are lowercase letters, digits and _, starting with a letter"
  module_exists "$name" && warn "a module called $name already exists; yours would replace it if newer"
  [[ -e "$target" ]] && die "$target already exists"
  [[ -d "$template" ]] || die "the module template isn't installed ($template)"

  cp -R "$template" "$target"
  find "$target" -type f -exec sed -i "s/__NAME__/$name/g; s/__SITECTL_VERSION__/$SITECTL_VERSION/g" {} +
  echo "Made $target from the template. Next:"
  echo "  1. Edit $target/module.conf and $target/module.sh"
  echo "  2. sitectl modules pack $target"
  echo "  3. sudo sitectl modules install $name-1.0.0.tar.gz"
}

cmd_modules() {
  local action="${1:-list}"
  shift || true
  case "$action" in
    list)      modules_list ;;
    info)      [[ $# -eq 1 ]] || die "usage: sitectl modules info <module>";       modules_info "$1" ;;
    enable)    [[ $# -eq 1 ]] || die "usage: sitectl modules enable <module>";     modules_enable "$1" ;;
    disable)   [[ $# -eq 1 ]] || die "usage: sitectl modules disable <module>";    modules_disable "$1" ;;
    install)   [[ $# -eq 1 ]] || die "usage: sitectl modules install <folder | file.tar.gz>"; modules_install "$1" ;;
    uninstall) [[ $# -eq 1 ]] || die "usage: sitectl modules uninstall <module>";  modules_uninstall "$1" ;;
    pack)      [[ $# -eq 1 ]] || die "usage: sitectl modules pack <folder>";       modules_pack "$1" ;;
    new)       [[ $# -eq 1 ]] || die "usage: sitectl modules new <name>";          modules_new "$1" ;;
    *)         die "usage: sitectl modules [list | info | enable | disable | install | uninstall | pack | new]" ;;
  esac
}
