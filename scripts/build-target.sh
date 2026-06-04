#!/bin/sh

set -eu

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

require_cmd curl
require_cmd gzip
require_cmd make
require_cmd sha256sum

ensure_imagebuilder
mkdir -p "$OUTPUT_DIR"

packages="$(resolve_packages target \
	"$PROJECT_DIR/profiles/packages-target.txt" \
	"$PROJECT_DIR/profiles/optional-packages.txt")"

log "Building installed target image"
clean_imagebuilder_output
make -C "$IMAGEBUILDER_DIR" image \
	PROFILE="$PROFILE" \
	PACKAGES="$packages" \
	FILES="$PROJECT_DIR/files-target" \
	ROOTFS_PARTSIZE="${TARGET_ROOTFS_PARTSIZE:-256}"

artifact="$(find_imagebuilder_artifact)"
cp "$artifact" "$OUTPUT_DIR/openwrt-x86-64-target.img.gz"
sha256sum "$OUTPUT_DIR/openwrt-x86-64-target.img.gz" > \
	"$OUTPUT_DIR/openwrt-x86-64-target.img.gz.sha256"
update_output_checksums

log "Target image ready: $OUTPUT_DIR/openwrt-x86-64-target.img.gz"
