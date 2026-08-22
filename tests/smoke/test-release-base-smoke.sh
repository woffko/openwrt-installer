#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON="$PROJECT_DIR/scripts/common.sh"
DOWNLOAD="$PROJECT_DIR/scripts/download-openwrt.sh"
MOUSE_BUILD="$PROJECT_DIR/scripts/build-mouse-packages.sh"
MOUSEDEV_PACKAGE="$PROJECT_DIR/packages/input-mousedev/Makefile"
GRUB_CONFIG="$PROJECT_DIR/iso/boot/grub/grub.cfg"
HYBRID_BUILD="$PROJECT_DIR/scripts/build-hybrid-iso.sh"
GRUB_FONT="$PROJECT_DIR/iso/boot/grub/fonts/hellforge.pf2"

assert_contains() {
	file="$1"
	text="$2"
	grep -F "$text" "$file" >/dev/null 2>&1 || {
		printf 'missing expected text in %s: %s\n' "$file" "$text" >&2
		exit 1
	}
}

assert_not_contains() {
	file="$1"
	text="$2"
	if grep -F "$text" "$file" >/dev/null 2>&1; then
		printf 'unexpected text in %s: %s\n' "$file" "$text" >&2
		exit 1
	fi
}

assert_contains "$COMMON" "OPENWRT_VERSION=\"\${OPENWRT_VERSION:-25.12.5}\""
assert_contains "$COMMON" 'IMAGEBUILDER_SHA256_25_12_5="313221253d9bac534e4a4ee6492a4941b4ba0f43200eceb8d16a4785470ae9df"'
assert_contains "$DOWNLOAD" "25.12.5) expected=\"\$IMAGEBUILDER_SHA256_25_12_5\""
assert_contains "$MOUSE_BUILD" 'SDK_SHA256="0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c"'
assert_contains "$MOUSEDEV_PACKAGE" 'PKG_VERSION:=6.12.94'
assert_contains "$GRUB_CONFIG" 'menuentry "OpenWrt x86 Installer"'
assert_contains "$GRUB_CONFIG" 'menuentry "Boot installed OpenWrt from local disk"'
assert_contains "$GRUB_CONFIG" 'menuentry "OpenWrt x86 Installer (serial 115200 8N1)"'
assert_contains "$GRUB_CONFIG" 'menuentry "OpenWrt x86 Installer (failsafe)"'
assert_contains "$GRUB_CONFIG" 'search --no-floppy --label kernel --set=owrt_local_boot'
assert_contains "$GRUB_CONFIG" 'set default="1"'
assert_contains "$GRUB_CONFIG" 'set default="0"'
assert_contains "$GRUB_CONFIG" 'owrt.mouse=1 owrt.check-latest=1'
assert_contains "$GRUB_CONFIG" 'owrt.console=dual'
assert_contains "$GRUB_CONFIG" 'owrt.console=ttyS0'
assert_contains "$GRUB_CONFIG" 'set gfxmode="1024x768x32,1024x768,800x600x32,800x600,auto"'
assert_contains "$GRUB_CONFIG" 'loadfont /boot/grub/fonts/hellforge.pf2'
assert_contains "$GRUB_CONFIG" 'terminal_output gfxterm serial'
assert_contains "$HYBRID_BUILD" "search --no-floppy --label OWRT_INSTALL --set=owrt_media"
assert_not_contains "$HYBRID_BUILD" "configfile (cd0)/boot/grub/grub.cfg"
assert_not_contains "$HYBRID_BUILD" "configfile (hd0,msdos1)/boot/grub/grub.cfg"
[ "$(sha256sum "$GRUB_FONT" | awk '{ print $1 }')" = \
	"28ac89d2977d68116093d696d50819abbd0125ddd4c25d3967583cace96c232a" ] || {
	printf 'GRUB font checksum changed unexpectedly\n' >&2
	exit 1
}
assert_contains "$GRUB_CONFIG" "configfile (\$owrt_local_boot)/boot/grub/grub.cfg"
assert_contains "$GRUB_CONFIG" "No installed OpenWrt boot partition with label 'kernel' was found."
assert_not_contains "$GRUB_CONFIG" 'menuentry "Download latest OpenWrt'
assert_not_contains "$GRUB_CONFIG" 'menuentry "OpenWrt 25.12.5'
[ "$(grep -c '^menuentry ' "$GRUB_CONFIG")" -eq 4 ] || {
	printf 'GRUB must expose exactly four menu entries\n' >&2
	exit 1
}

printf 'OpenWrt release base and local-disk GRUB smoke tests passed.\n'
