#!/bin/sh

set -eu

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

require_cmd curl
require_cmd sha256sum
require_cmd tar
require_cmd zstd

mkdir -p "$BUILD_DIR/cache"

archive="$BUILD_DIR/cache/$IMAGEBUILDER_ARCHIVE"

case "$OPENWRT_VERSION" in
	25.12.5) expected="$IMAGEBUILDER_SHA256_25_12_5" ;;
	*) die "No pinned ImageBuilder checksum for OpenWrt $OPENWRT_VERSION" ;;
esac

if [ ! -f "$archive" ]; then
	log "Downloading OpenWrt $OPENWRT_VERSION ImageBuilder"
	curl -fL --retry 3 -o "$archive.tmp" "$IMAGEBUILDER_URL"
	mv "$archive.tmp" "$archive"
fi

log "Verifying $IMAGEBUILDER_ARCHIVE"
printf '%s  %s\n' "$expected" "$archive" | sha256sum -c -

if ! imagebuilder_ready; then
	log "Extracting ImageBuilder"
	tar --zstd -xf "$archive" -C "$BUILD_DIR"
fi

imagebuilder_ready || die "Extracted ImageBuilder is incomplete: $IMAGEBUILDER_DIR"
log "ImageBuilder ready: $IMAGEBUILDER_DIR"
