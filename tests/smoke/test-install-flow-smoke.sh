#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INSTALLER="$PROJECT_DIR/files-installer/usr/sbin/owrt-install"
UI_LIB="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-ui"
TMPDIR="${TMPDIR:-/tmp}"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	file="$1"
	pattern="$2"
	if ! grep -F "$pattern" "$file" >/dev/null 2>&1; then
		printf '%s\n' "--- $file ---" >&2
		sed -n '1,200p' "$file" >&2 || true
		fail "Expected output to contain: $pattern"
	fi
}

assert_not_contains() {
	file="$1"
	pattern="$2"
	if grep -F "$pattern" "$file" >/dev/null 2>&1; then
		printf '%s\n' "--- $file ---" >&2
		sed -n '1,200p' "$file" >&2 || true
		fail "Output must not contain: $pattern"
	fi
}

run_parse_args_smoke() {
	work_dir="$1"
	out_file="$work_dir/parse-args.out"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$work_dir" UI_LIB="$UI_LIB" sh -eu -c '
		. "$1"
		parse_args \
			--target /dev/testdisk \
			--skip-network-wizard \
			--dry-run \
			--yes-i-know-this-will-erase-data \
			--lan-ip 10.10.10.1/24 \
			--wan-proto disabled
		printf "action=%s\n" "$action"
		printf "target=%s\n" "$TARGET"
		printf "skip_network=%s\n" "$SKIP_NETWORK"
		printf "dry_run=%s\n" "$DRY_RUN"
		printf "assume_yes=%s\n" "$ASSUME_YES"
		printf "lan=%s/%s %s\n" "$LAN_IP" "$LAN_CIDR" "$LAN_NETMASK"
		printf "wan=%s wan6=%s\n" "$WAN_PROTO" "$WAN6_PROTO"
		cleanup
	' sh "$INSTALLER" > "$out_file" 2>&1

	assert_contains "$out_file" "action=install"
	assert_contains "$out_file" "target=/dev/testdisk"
	assert_contains "$out_file" "skip_network=1"
	assert_contains "$out_file" "dry_run=1"
	assert_contains "$out_file" "assume_yes=1"
	assert_contains "$out_file" "lan=10.10.10.1/24 255.255.255.0"
	assert_contains "$out_file" "wan=disabled wan6=disabled"
}

run_dry_run_skip_network_smoke() {
	work_dir="$1"
	out_file="$work_dir/dry-run.out"
	calls_file="$work_dir/dry-run.calls"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$work_dir" UI_LIB="$UI_LIB" OWRT_UI_MODE=line TERM=dumb sh -eu -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		TARGET="/dev/testdisk"
		SKIP_NETWORK=1
		DRY_RUN=1
		ASSUME_YES=1
		CALLS_FILE="$3"

		record() {
			printf "%s\n" "$1" >> "$CALLS_FILE"
		}

		forbidden() {
			record "$1"
			printf "forbidden call: %s\n" "$1" >&2
			exit 1
		}

		setup_ui() { record setup_ui; }
		ui_welcome_screen() { record ui_welcome_screen; }
		ui_install_stage() { record "stage:$1"; }
		verify_payload() {
			record verify_payload
			PAYLOAD_SHA256=fake-sha
		}
		validate_target_disk() { record "validate_target:$1"; }
		review_and_confirm() { record review_and_confirm; }
		select_target_disk() { forbidden select_target_disk; }
		select_network() { forbidden select_network; }
		validate_network_selection() { forbidden validate_network_selection; }
		validate_network_settings() { forbidden validate_network_settings; }
		unmount_target_partitions() { forbidden unmount_target_partitions; }
		write_payload() { forbidden write_payload; }
		resize_rootfs() { forbidden resize_rootfs; }
		write_installed_config() { forbidden write_installed_config; }

		run_install
		cleanup
	' sh "$INSTALLER" "$work_dir" "$calls_file" > "$out_file" 2>&1

	assert_contains "$calls_file" "setup_ui"
	assert_contains "$calls_file" "verify_payload"
	assert_contains "$calls_file" "validate_target:/dev/testdisk"
	assert_contains "$calls_file" "review_and_confirm"
	assert_contains "$out_file" "Dry run complete; no changes were made"
	assert_not_contains "$calls_file" "select_network"
	assert_not_contains "$calls_file" "write_payload"
	assert_not_contains "$calls_file" "resize_rootfs"
	assert_not_contains "$calls_file" "write_installed_config"
}

[ -r "$INSTALLER" ] || fail "Installer not found: $INSTALLER"
[ -r "$UI_LIB" ] || fail "UI library not found: $UI_LIB"

work_dir="$(mktemp -d "$TMPDIR/owrt-install-flow-smoke.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT INT TERM

run_parse_args_smoke "$work_dir"
run_dry_run_skip_network_smoke "$work_dir"

printf 'Install flow smoke tests passed.\n'
