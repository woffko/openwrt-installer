#!/bin/sh

set -eu

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

require_cmd curl
require_cmd date
require_cmd gzip
require_cmd make
require_cmd sha256sum

ensure_imagebuilder
mkdir -p "$OUTPUT_DIR" "$PROJECT_DIR/files-installer/usr/share/owrt-installer"

target_image="$OUTPUT_DIR/openwrt-x86-64-target.img.gz"
payload="$PROJECT_DIR/files-installer/usr/share/owrt-installer/target.img.gz"
manifest="$PROJECT_DIR/files-installer/usr/share/owrt-installer/manifest.json"

[ -s "$target_image" ] || die "Target image is missing. Run: make target"

log "Embedding target payload"
cp "$target_image" "$payload"
payload_sha256="$(sha256sum "$payload" | awk '{ print $1 }')"
payload_uncompressed_size="$(gzip -dc "$payload" | wc -c | tr -d ' ')"
build_date="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

cat > "$manifest" <<EOF
{
  "installer_version": "$INSTALLER_VERSION",
  "build_date": "$build_date",
  "openwrt_version": "$OPENWRT_VERSION",
  "target_arch": "x86_64",
  "target_profile": "$PROFILE",
  "image_type": "$IMAGE_TYPE",
  "payload_filename": "target.img.gz",
  "payload_sha256": "$payload_sha256",
  "payload_uncompressed_size": "$payload_uncompressed_size"
}
EOF
cp "$manifest" "$OUTPUT_DIR/manifest.json"

packages="$(resolve_packages installer \
	"$PROJECT_DIR/profiles/packages-installer.txt" \
	"$PROJECT_DIR/profiles/optional-packages.txt")"

log "Building live installer image"
clean_imagebuilder_output
make -C "$IMAGEBUILDER_DIR" image \
	PROFILE="$PROFILE" \
	PACKAGES="$packages" \
	FILES="$PROJECT_DIR/files-installer" \
	ROOTFS_PARTSIZE="${INSTALLER_ROOTFS_PARTSIZE:-512}"

artifact="$(find_imagebuilder_artifact)"
cp "$artifact" "$OUTPUT_DIR/openwrt-x86-64-installer.img.gz"
write_sidecar_checksum "$OUTPUT_DIR/openwrt-x86-64-installer.img.gz"
update_output_checksums

log "Installer image ready: $OUTPUT_DIR/openwrt-x86-64-installer.img.gz"
