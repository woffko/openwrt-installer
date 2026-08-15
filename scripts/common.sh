#!/bin/sh

set -eu

# ImageBuilder preserves the caller's umask in generated rootfs archives.
# Keep service users and packaged executables usable across build runners.
umask 022

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/output}"
# Do not leak WSL Windows PATH entries into ImageBuilder. Some contain spaces
# and make GNU find reject -execdir during rootfs preparation.
PATH="$BUILD_DIR/host-tools/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.5}"
INSTALLER_VERSION="${INSTALLER_VERSION:-v1.0-alpha.10}"
PROFILE="generic"
IMAGE_TYPE="ext4-combined-efi"
IMAGEBUILDER_ARCHIVE="openwrt-imagebuilder-${OPENWRT_VERSION}-x86-64.Linux-x86_64.tar.zst"
IMAGEBUILDER_DIR="$BUILD_DIR/openwrt-imagebuilder-${OPENWRT_VERSION}-x86-64.Linux-x86_64"
# shellcheck disable=SC2034 # Used by scripts that source this file.
IMAGEBUILDER_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64/${IMAGEBUILDER_ARCHIVE}"
# shellcheck disable=SC2034 # Used by scripts that source this file.
IMAGEBUILDER_SHA256_25_12_5="313221253d9bac534e4a4ee6492a4941b4ba0f43200eceb8d16a4785470ae9df"

log() {
	printf '[owrt-installer] %s\n' "$*" >&2
}

die() {
	printf '[owrt-installer] ERROR: %s\n' "$*" >&2
	exit 1
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Required host command not found: $1"
}

read_package_file() {
	awk '
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{ print $1 }
	' "$1"
}

imagebuilder_ready() {
	[ -f "$IMAGEBUILDER_DIR/Makefile" ] &&
		[ -f "$IMAGEBUILDER_DIR/repositories" ] &&
		[ -x "$IMAGEBUILDER_DIR/staging_dir/host/bin/apk" ]
}

ensure_imagebuilder() {
	if ! imagebuilder_ready; then
		"$PROJECT_DIR/scripts/download-openwrt.sh"
	fi
	imagebuilder_ready || die "ImageBuilder is incomplete after extraction: $IMAGEBUILDER_DIR"
}

refresh_available_packages() {
	cache="$BUILD_DIR/available-packages-${OPENWRT_VERSION}.txt"
	tmp="$cache.tmp"
	repos="$IMAGEBUILDER_DIR/repositories"
	apk="$IMAGEBUILDER_DIR/staging_dir/host/bin/apk"
	apk_root="$BUILD_DIR/package-index-root"
	apk_cache="$BUILD_DIR/package-index-cache"

	[ -f "$repos" ] || die "ImageBuilder repositories file not found: $repos"
	[ -x "$apk" ] || die "ImageBuilder apk tool not found: $apk"
	mkdir -p "$BUILD_DIR"
	mkdir -p "$apk_root/etc/apk" "$apk_root/var/cache/apk" "$apk_cache"

	log "Refreshing package index"
	if [ ! -f "$apk_root/lib/apk/db/installed" ]; then
		"$apk" --root "$apk_root" --initdb --usermode --allow-untrusted add >/dev/null
	fi
	"$apk" \
		--root "$apk_root" \
		--keys-dir "$IMAGEBUILDER_DIR/keys" \
		--repositories-file "$repos" \
		--cache-dir "$apk_cache" \
		--allow-untrusted \
		update >/dev/null
	"$apk" \
		--root "$apk_root" \
		--keys-dir "$IMAGEBUILDER_DIR/keys" \
		--repositories-file "$repos" \
		--cache-dir "$apk_cache" \
		--allow-untrusted \
		query --from repositories --fields name '*' |
		sed -n 's/^Name: //p' > "$tmp"

	sort -u "$tmp" > "$cache"
	rm -f "$tmp"
	printf '%s\n' "$cache"
}

available_packages_file() {
	cache="$BUILD_DIR/available-packages-${OPENWRT_VERSION}.txt"
	if [ ! -s "$cache" ]; then
		refresh_available_packages
	else
		printf '%s\n' "$cache"
	fi
}

package_exists() {
	pkg="$1"
	index="$2"
	grep -Fx "$pkg" "$index" >/dev/null 2>&1 && return 0
	find "$IMAGEBUILDER_DIR/packages" -maxdepth 1 -type f \
		-name "$pkg-*.apk" -print -quit 2>/dev/null | grep -q .
}

resolve_packages() {
	scope="$1"
	required_file="$2"
	optional_file="$3"
	index="$(available_packages_file)"
	result=""

	for pkg in $(read_package_file "$required_file"); do
		package_exists "$pkg" "$index" ||
			die "Required package is unavailable for OpenWrt $OPENWRT_VERSION: $pkg"
		result="$result $pkg"
	done

	while read -r pkg_scope pkg extra; do
		case "$pkg_scope" in
			""|\#*) continue ;;
		esac
		[ -z "${extra:-}" ] || die "Invalid optional package entry: $pkg_scope $pkg $extra"
		case "$pkg_scope" in
			all|"$scope") ;;
			target|installer) continue ;;
			*) die "Invalid optional package scope: $pkg_scope" ;;
		esac
		if package_exists "$pkg" "$index"; then
			result="$result $pkg"
		else
			log "Optional package unavailable, skipping: $pkg"
		fi
	done < "$optional_file"

	printf '%s\n' "$result"
}

clean_imagebuilder_output() {
	rm -rf "$IMAGEBUILDER_DIR/bin/targets/x86/64"
}

find_imagebuilder_artifact() {
	artifact="$(find "$IMAGEBUILDER_DIR/bin/targets/x86/64" -type f \
		-name "*-${PROFILE}-${IMAGE_TYPE}.img.gz" 2>/dev/null | head -n 1)"
	[ -n "$artifact" ] || die "ImageBuilder did not produce ${PROFILE}-${IMAGE_TYPE}.img.gz"
	printf '%s\n' "$artifact"
}

write_sidecar_checksum() {
	file="$1"
	dir="$(dirname "$file")"
	name="$(basename "$file")"
	(
		cd "$dir"
		sha256sum "$name"
	) > "$file.sha256"
}

update_output_checksums() {
	mkdir -p "$OUTPUT_DIR"
	tmp="$OUTPUT_DIR/sha256sums.txt.tmp"
	(
		cd "$OUTPUT_DIR"
		for file in \
			openwrt-x86-64-target.img.gz \
			openwrt-x86-64-installer.img.gz \
			openwrt-x86-64-installer-hybrid.iso \
			manifest.json
		do
			if [ -f "$file" ]; then
				sha256sum "$file"
			fi
		done
	) > "$tmp"
	mv "$tmp" "$OUTPUT_DIR/sha256sums.txt"
}
