#!/bin/sh

set -eu

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

SDK_NAME="openwrt-sdk-${OPENWRT_VERSION}-x86-64_gcc-14.3.0_musl.Linux-x86_64"
SDK_ARCHIVE="$BUILD_DIR/cache/$SDK_NAME.tar.zst"
SDK_DIR="$BUILD_DIR/$SDK_NAME"
SDK_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64/$SDK_NAME.tar.zst"
SDK_SHA256="28e004c1be4d215d19c1f12a6aa4c8d8f80689549eb707d0ff5a71f16fa8d05f"
CUSTOM_PACKAGE_DIR="$BUILD_DIR/custom-packages"
IMAGEBUILDER_PACKAGE_DIR="$IMAGEBUILDER_DIR/packages"
ZSTD="$BUILD_DIR/host-tools/usr/bin/zstd"

require_cmd curl
require_cmd sha256sum
require_cmd tar
[ -x "$ZSTD" ] || die "Local zstd is missing. Run: make iso-host-tools"
mkdir -p "$BUILD_DIR/cache" "$CUSTOM_PACKAGE_DIR" "$IMAGEBUILDER_PACKAGE_DIR"

if [ ! -s "$SDK_ARCHIVE" ]; then
	log "Downloading OpenWrt SDK $OPENWRT_VERSION"
	curl -fL --continue-at - "$SDK_URL" -o "$SDK_ARCHIVE"
fi
printf '%s  %s\n' "$SDK_SHA256" "$SDK_ARCHIVE" | sha256sum -c -

if [ ! -f "$SDK_DIR/Makefile" ]; then
	log "Extracting OpenWrt SDK"
	tar -I "$ZSTD" -xf "$SDK_ARCHIVE" -C "$BUILD_DIR"
fi

log "Synchronizing pinned SDK feeds"
(
	cd "$SDK_DIR"
	./scripts/feeds update base packages
	./scripts/feeds install popt slang2
	[ ! -L package/feeds/packages/newt ] || unlink package/feeds/packages/newt
	ln -sfn "$PROJECT_DIR/packages/newt-gpm" package/owrt-newt-gpm
	ln -sfn "$PROJECT_DIR/packages/gpm-daemon" package/owrt-gpm-daemon
	cp "$PROJECT_DIR/profiles/sdk-mouse-packages.config" .config
	make defconfig
	for disabled in slsh libslang2-modules libslang2-mod-base64 \
		libslang2-mod-chksum libslang2-mod-csv libslang2-mod-fcntl \
		libslang2-mod-fork libslang2-mod-histogram libslang2-mod-iconv \
		libslang2-mod-json libslang2-mod-onig libslang2-mod-png \
		libslang2-mod-rand libslang2-mod-select libslang2-mod-slsmg \
		libslang2-mod-socket libslang2-mod-stats libslang2-mod-sysconf \
		libslang2-mod-termios libslang2-mod-varray libslang2-mod-zlib
	do
		if grep -Eq "^CONFIG_PACKAGE_${disabled}=[my]" .config; then
			die "Unexpected S-Lang companion package enabled: $disabled"
		fi
		done
	make package/owrt-newt-gpm/clean package/owrt-gpm-daemon/clean
	make package/owrt-newt-gpm/compile V=sc
	make package/owrt-gpm-daemon/compile V=sc
)

newt_apk="$(find "$SDK_DIR/bin/packages" -type f -name 'libnewt-0.52.24-r2.apk' | head -n 1)"
whiptail_apk="$(find "$SDK_DIR/bin/packages" -type f -name 'whiptail-0.52.24-r2.apk' | head -n 1)"
gpm_apk="$(find "$SDK_DIR/bin/packages" -type f -name 'gpm-daemon-1.20.7-r4.apk' | head -n 1)"

rm -f "$CUSTOM_PACKAGE_DIR/libnewt-"*.apk \
	"$CUSTOM_PACKAGE_DIR/whiptail-"*.apk \
	"$CUSTOM_PACKAGE_DIR/gpm-daemon-"*.apk \
	"$IMAGEBUILDER_PACKAGE_DIR/libnewt-"*.apk \
	"$IMAGEBUILDER_PACKAGE_DIR/whiptail-"*.apk \
	"$IMAGEBUILDER_PACKAGE_DIR/gpm-daemon-"*.apk

for package_file in "$newt_apk" "$whiptail_apk" "$gpm_apk"; do
	[ -s "$package_file" ] || die "Expected custom mouse package was not built"
	cp "$package_file" "$CUSTOM_PACKAGE_DIR/"
	cp "$package_file" "$IMAGEBUILDER_PACKAGE_DIR/"
done

sha256sum \
	"$CUSTOM_PACKAGE_DIR/$(basename "$newt_apk")" \
	"$CUSTOM_PACKAGE_DIR/$(basename "$whiptail_apk")" \
	"$CUSTOM_PACKAGE_DIR/$(basename "$gpm_apk")"
log "Custom local-console mouse packages are ready"
