#!/bin/sh

set -eu

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

require_cmd apt-get
require_cmd dpkg-deb

cache_dir="$BUILD_DIR/cache/iso-host-tools"
tools_dir="$BUILD_DIR/host-tools"

mkdir -p "$cache_dir" "$tools_dir"

log "Downloading local hybrid ISO host tools"
(
	cd "$cache_dir"
	apt-get download cpio xorriso libisoburn1t64 libburn4t64 libisofs6t64
)

for archive in "$cache_dir"/*.deb; do
	dpkg-deb -x "$archive" "$tools_dir"
done

log "Local ISO host tools ready: $tools_dir/usr/bin/xorrisofs"
