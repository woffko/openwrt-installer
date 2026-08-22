#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INSTALLER="$PROJECT_DIR/files-installer/usr/sbin/owrt-install"
UI_LIB="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-ui"
export UI_LIB
TMPDIR="${TMPDIR:-/tmp}"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	file="$1"
	pattern="$2"
	grep -F -- "$pattern" "$file" >/dev/null 2>&1 || {
		printf '%s\n' "--- $file ---" >&2
		sed -n '1,180p' "$file" >&2 || true
		fail "Expected output to contain: $pattern"
	}
}

suite="$(mktemp -d "$TMPDIR/owrt-custom-build-smoke.XXXXXX")"
trap 'rm -rf "$suite"' EXIT INT TERM HUP
mkdir -p "$suite/local/CUSTOM_BUILD" "$suite/usb/CUSTOM_BUILD" \
	"$suite/usb/CUSTOM_BUILD/nested"

raw="$suite/custom.raw"
valid="$suite/usb/CUSTOM_BUILD/openwrt-25.12.5-x86-64-generic-ext4-combined.img.gz"
dd if=/dev/zero of="$raw" bs=1M count=1 status=none
gzip -c "$raw" > "$valid"
valid_sha="$(sha256sum "$valid" | awk '{ print $1 }')"
printf '%s  %s\n' "$valid_sha" "$(basename "$valid")" > "$valid.sha256"
cp "$valid" "$suite/local/CUSTOM_BUILD/my custom build.img.gz"
cp "$valid" "$suite/usb/CUSTOM_BUILD/nested/ignored.img.gz"
ln -s "$valid" "$suite/usb/CUSTOM_BUILD/symlink.img.gz"

printf '%s|%s|%s|%s|%s\n' \
	"/dev/test-usb1" "vfat" "10485760" "CUSTOM-USB" "$suite/usb" \
	> "$suite/partitions.list"

OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_IMPORT_TEST_MODE=1 \
OWRT_CUSTOM_BUILD_TEST_MODE=1 OWRT_CUSTOM_BUILD_LOCAL_ROOT="$suite/local" \
OWRT_IMPORT_TEST_PARTITIONS_FILE="$suite/partitions.list" TMPDIR="$suite" \
	sh -eu -c '
		. "$1"
		custom_build_discover
		cat "$CUSTOM_BUILD_LIST"
		printf "count=%s\n" "$(wc -l < "$CUSTOM_BUILD_LIST" | tr -d " ")"
	' sh "$INSTALLER" > "$suite/discovery.out" 2>&1 ||
	{ sed -n '1,180p' "$suite/discovery.out" >&2 || true; fail "CUSTOM_BUILD discovery smoke failed"; }
assert_contains "$suite/discovery.out" "my custom build.img.gz"
assert_contains "$suite/discovery.out" "openwrt-25.12.5-x86-64-generic-ext4-combined.img.gz"
assert_contains "$suite/discovery.out" "count=2"
if grep -F 'nested/ignored' "$suite/discovery.out" >/dev/null 2>&1 ||
	grep -F 'symlink.img.gz' "$suite/discovery.out" >/dev/null 2>&1; then
	fail "CUSTOM_BUILD discovery accepted a nested image or symlink"
fi

OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_CUSTOM_BUILD_TEST_MODE=1 \
OWRT_CUSTOM_BUILD_TEST_BOOT_MODE=bios OWRT_CUSTOM_BUILD_TEST_MEM_AVAILABLE=1073741824 \
OWRT_CUSTOM_BUILD_RAM_RESERVE_BYTES=1048576 TMPDIR="$suite" \
	sh -eu -c '
		. "$1"
		ui_install_stage() { :; }
		autostart_serial_marker() { printf "marker=%s\n" "$1"; }
		storage_inspect_payload_layout() {
			printf "layout_mode=%s size=%s\n" "$3" "$2"
			[ "$3" = bios ] || return 1
			STORAGE_TABLE_TYPE=dos
			STORAGE_PAYLOAD_SECTOR_SIZE=512
			STORAGE_ROOT_START_SECTOR=2048
			STORAGE_ROOT_IMAGE_END_SECTOR=2047
		}
		custom_build_prepare_path "$2" "test USB /CUSTOM_BUILD"
		printf "source=%s version=%s trust=%s file=%s\n" \
			"$PAYLOAD_SOURCE_ID" "$PAYLOAD_VERSION" \
			"$PAYLOAD_CUSTOM_CHECKSUM_STATUS" "$PAYLOAD_FILENAME"
		printf "manifest_sha=%s\n" "$(json_value payload_sha256)"
		printf "copied_mode=%s\n" "$(stat -c %a "$PAYLOAD")"
	' sh "$INSTALLER" "$valid" > "$suite/valid.out" 2>&1 ||
	fail "Valid custom build staging smoke failed"
assert_contains "$suite/valid.out" "layout_mode=bios size=1048576"
assert_contains "$suite/valid.out" "source=custom-build version=custom-25.12.5 trust=sidecar-verified-unsigned"
assert_contains "$suite/valid.out" "manifest_sha=$valid_sha"
assert_contains "$suite/valid.out" "copied_mode=600"
assert_contains "$suite/valid.out" "marker=OWRT_INSTALLER_CUSTOM_BUILD_VERIFIED=1"

OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_CUSTOM_BUILD_TEST_MODE=1 \
OWRT_CUSTOM_BUILD_TEST_BOOT_MODE=bios OWRT_CUSTOM_BUILD_TEST_MEM_AVAILABLE=1073741824 \
OWRT_CUSTOM_BUILD_RAM_RESERVE_BYTES=1048576 TMPDIR="$suite" \
	sh -eu -c '
		. "$1"
		ui_install_stage() { :; }
		autostart_serial_marker() { :; }
		custom_test_mounted=0
		config_import_mount_source() {
			CONFIG_IMPORT_MOUNTDIR="$3"
			custom_test_mounted=1
		}
		config_import_unmount_source() {
			custom_test_mounted=0
			CONFIG_IMPORT_MOUNTDIR=""
			CONFIG_IMPORT_MOUNTED=0
		}
		storage_inspect_payload_layout() {
			printf "mounted_during_layout=%s\n" "$custom_test_mounted"
			[ "$custom_test_mounted" = 0 ]
		}
		CUSTOM_BUILD_SELECTED_LINE="1|/dev/test-usb1|vfat|CUSTOM_BUILD/$4|CUSTOM-USB|$3|$4|1"
		custom_build_prepare_selected
	' sh "$INSTALLER" "$valid" "$suite/usb" "$(basename "$valid")" \
	> "$suite/unmount-order.out" 2>&1 ||
	fail "Custom source unmount-order smoke failed"
assert_contains "$suite/unmount-order.out" "mounted_during_layout=0"

unsigned="$suite/local/CUSTOM_BUILD/my custom build.img.gz"
OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_CUSTOM_BUILD_TEST_MODE=1 \
OWRT_CUSTOM_BUILD_TEST_BOOT_MODE=bios OWRT_CUSTOM_BUILD_TEST_MEM_AVAILABLE=1073741824 \
OWRT_CUSTOM_BUILD_RAM_RESERVE_BYTES=1048576 TMPDIR="$suite" \
	sh -eu -c '
		. "$1"
		ui_install_stage() { :; }
		autostart_serial_marker() { :; }
		storage_inspect_payload_layout() { [ "$3" = bios ]; }
		custom_build_prepare_path "$2" "runtime /CUSTOM_BUILD"
		printf "trust=%s version=%s\n" "$PAYLOAD_CUSTOM_CHECKSUM_STATUS" "$PAYLOAD_VERSION"
	' sh "$INSTALLER" "$unsigned" > "$suite/unsigned.out" 2>&1 ||
	fail "Unsigned custom build staging smoke failed"
assert_contains "$suite/unsigned.out" "trust=locally-computed-unsigned version=custom-unsigned"

printf '%064d  %s\n' 0 "$(basename "$valid")" > "$valid.sha256"
OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_CUSTOM_BUILD_TEST_MODE=1 \
OWRT_CUSTOM_BUILD_TEST_BOOT_MODE=bios OWRT_CUSTOM_BUILD_TEST_MEM_AVAILABLE=1073741824 \
OWRT_CUSTOM_BUILD_RAM_RESERVE_BYTES=1048576 TMPDIR="$suite" \
	sh -eu -c '
		. "$1"
		ui_install_stage() { :; }
		autostart_serial_marker() { :; }
		storage_inspect_payload_layout() { return 0; }
		status=0
		custom_build_prepare_path "$2" "test USB" || status=$?
		printf "status=%s error=%s\n" "$status" "$CUSTOM_BUILD_ERROR"
	' sh "$INSTALLER" "$valid" > "$suite/mismatch.out" 2>&1 ||
	fail "Checksum mismatch smoke harness failed"
assert_contains "$suite/mismatch.out" "status=1 error=The custom image SHA-256 does not match"
printf '%s  %s\n' "$valid_sha" "$(basename "$valid")" > "$valid.sha256"

OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_CUSTOM_BUILD_TEST_MODE=1 \
OWRT_CUSTOM_BUILD_TEST_BOOT_MODE=bios OWRT_CUSTOM_BUILD_TEST_MEM_AVAILABLE=1 \
OWRT_CUSTOM_BUILD_RAM_RESERVE_BYTES=1048576 TMPDIR="$suite" \
	sh -eu -c '
		. "$1"
		ui_install_stage() { :; }
		status=0
		custom_build_prepare_path "$2" "test USB" || status=$?
		printf "status=%s error=%s\n" "$status" "$CUSTOM_BUILD_ERROR"
	' sh "$INSTALLER" "$valid" > "$suite/low-ram.out" 2>&1 ||
	fail "Low-RAM custom build smoke harness failed"
assert_contains "$suite/low-ram.out" "status=1 error=Insufficient RAM"

OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_CUSTOM_BUILD_TEST_MODE=1 \
OWRT_CUSTOM_BUILD_TEST_BOOT_MODE=bios OWRT_CUSTOM_BUILD_TEST_MEM_AVAILABLE=1073741824 \
OWRT_CUSTOM_BUILD_RAM_RESERVE_BYTES=1048576 OWRT_CUSTOM_BUILD_MAX_UNCOMPRESSED_BYTES=524288 \
TMPDIR="$suite" sh -eu -c '
		. "$1"
		ui_install_stage() { :; }
		status=0
		custom_build_prepare_path "$2" "test USB" || status=$?
		printf "status=%s error=%s\n" "$status" "$CUSTOM_BUILD_ERROR"
	' sh "$INSTALLER" "$valid" > "$suite/decompressed-limit.out" 2>&1 ||
	fail "Decompressed-limit custom build smoke harness failed"
assert_contains "$suite/decompressed-limit.out" "status=1 error=The custom image exceeds"

OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$suite" sh -eu -c '
	. "$1"
	ui_install_stage() { :; }
	custom_build_discover() { return 1; }
	check_for_newer_payload() { printf "automatic-flow=kept\n"; }
	CHECK_LATEST=1
	prepare_initial_payload
' sh "$INSTALLER" > "$suite/no-custom-flow.out" 2>&1 ||
	fail "No-custom automatic flow smoke failed"
assert_contains "$suite/no-custom-flow.out" "automatic-flow=kept"

printf 'CUSTOM_BUILD smoke tests passed.\n'
