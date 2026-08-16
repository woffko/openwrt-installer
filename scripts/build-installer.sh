#!/bin/sh

set -eu

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

require_cmd curl
require_cmd date
require_cmd gzip
require_cmd git
require_cmd make
require_cmd sha256sum

ensure_imagebuilder
mkdir -p "$OUTPUT_DIR" "$PROJECT_DIR/files-installer/usr/share/owrt-installer"

target_image="$OUTPUT_DIR/openwrt-x86-64-target.img.gz"
target_version_file="$OUTPUT_DIR/openwrt-x86-64-target.version"
payload="$PROJECT_DIR/files-installer/usr/share/owrt-installer/target.img.gz"
manifest="$PROJECT_DIR/files-installer/usr/share/owrt-installer/manifest.json"
network_applier="$PROJECT_DIR/files-installer/usr/share/owrt-installer/98-installer-network"
guard_asset_dir="$PROJECT_DIR/files-installer/usr/share/owrt-installer/storage-guard"

[ -s "$target_image" ] || die "Target image is missing. Run: make target"
[ -s "$target_version_file" ] || die "Target version marker is missing. Run: make target"
target_version="$(sed -n '1p' "$target_version_file")"
[ "$target_version" = "$OPENWRT_VERSION" ] ||
	die "Target image is OpenWrt $target_version, expected $OPENWRT_VERSION. Run: make target"

log "Embedding target payload"
cp "$target_image" "$payload"
cp "$PROJECT_DIR/files-target/etc/uci-defaults/98-installer-network" "$network_applier"
chmod 0755 "$network_applier"
mkdir -p "$guard_asset_dir"
cp "$PROJECT_DIR/files-target/etc/owrt-installer/upgrade-guard" \
	"$guard_asset_dir/upgrade-guard"
cp "$PROJECT_DIR/files-target/etc/owrt-installer/sysupgrade-wrapper" \
	"$guard_asset_dir/sysupgrade-wrapper"
cp "$PROJECT_DIR/files-target/etc/owrt-installer/install-upgrade-guard" \
	"$guard_asset_dir/install-upgrade-guard"
cp "$PROJECT_DIR/files-target/etc/init.d/owrt-installer-guard" \
	"$guard_asset_dir/owrt-installer-guard.init"
chmod 0755 "$guard_asset_dir"/*
payload_sha256="$(sha256sum "$payload" | awk '{ print $1 }')"
payload_uncompressed_size="$(gzip -dc "$payload" | wc -c | tr -d ' ')"
build_date="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
build_commit="$(git -C "$PROJECT_DIR" rev-parse --verify 'HEAD^{commit}')"
if [ -n "$(git -C "$PROJECT_DIR" status --porcelain=v1 --untracked-files=all)" ]; then
	build_dirty=true
else
	build_dirty=false
fi

cat > "$manifest" <<EOF
{
  "installer_version": "$INSTALLER_VERSION",
  "build_date": "$build_date",
  "build_commit": "$build_commit",
  "build_dirty": $build_dirty,
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
