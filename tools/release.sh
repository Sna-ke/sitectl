#!/usr/bin/env bash
#
# tools/release.sh: make a sitectl release tarball.
#
#   ./tools/release.sh
#
# Writes CHECKSUMS for each bundled module (so they can be packed and
# installed on their own too), checks everything parses, and makes
# sitectl-<version>.tar.gz in the folder above the project.

set -euo pipefail

PROJECT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$PROJECT"

version=$(sed -n 's/^SITECTL_VERSION="\(.*\)"/\1/p' bin/sitectl)
[[ -n "$version" ]] || { echo "Error: no SITECTL_VERSION in bin/sitectl" >&2; exit 1; }

echo "==> Checking syntax"
for file in bin/sitectl lib/*.sh lib/modules/*/module.sh install.sh uninstall.sh tests/run-tests.sh; do
  bash -n "$file"
done

echo "==> Writing module CHECKSUMS"
for module in lib/modules/*/; do
  module="${module%/}"
  sums=$(cd "$module" && find . -type f ! -name CHECKSUMS | sed 's|^\./||' | LC_ALL=C sort |
         xargs -d '\n' sha256sum)
  printf '%s\n' "$sums" > "$module/CHECKSUMS"
  echo "  $module ($(sed -n 's/^version=//p' "$module/module.conf"))"
done

echo "==> Packing"
archive="$PROJECT/../sitectl-$version.tar.gz"
tar --owner=0 --group=0 --exclude=./.git --exclude=./.gitignore \
    --exclude='*~' --exclude='*.swp' --exclude='*.tar.gz' \
    --transform "s|^\.|sitectl-$version|" -czf "$archive" .
echo "  $(readlink -f "$archive")"
