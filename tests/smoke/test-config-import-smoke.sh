#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INSTALLER="$PROJECT_DIR/files-installer/usr/sbin/owrt-install"
UI_LIB="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-ui"
IMPORT_LIB="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-config-import"
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
		sed -n '1,200p' "$file" >&2 || true
		fail "Expected output to contain: $pattern"
	}
}

assert_not_exists() {
	[ ! -e "$1" ] || fail "Path must not exist: $1"
}

write_valid_tree() {
	fixture_tree="$1"
	mkdir -p "$fixture_tree/etc/config" "$fixture_tree/etc/uci-defaults" "$fixture_tree/etc/owrt-installer"
	printf '%s\n' "config interface 'lan'" "option device 'br-imported'" > "$fixture_tree/etc/config/network"
	printf '%s\n' "config system 'system'" "option hostname 'imported-router'" > "$fixture_tree/etc/config/system"
	# shellcheck disable=SC2016 # Literal password-hash fixture.
	printf '%s\n' 'root:$1$imported$hash:0:0:99999:7:::' > "$fixture_tree/etc/shadow"
	printf '%s\n' '#!/bin/sh' 'exit 0' > "$fixture_tree/etc/uci-defaults/10_disable_services"
	chmod 0755 "$fixture_tree/etc/uci-defaults/10_disable_services"
	printf '%s\n' 'LAN_MAC=stale' > "$fixture_tree/etc/owrt-installer/interface-map"
	printf '%s\n' '#!/bin/sh' 'exit 0' > "$fixture_tree/etc/uci-defaults/98-installer-network"
	chmod 0755 "$fixture_tree/etc/uci-defaults/98-installer-network"
	printf '%s\n' 'installed_by=forged-backup' > "$fixture_tree/etc/openwrt-installer-release"
}

make_archive() {
	fixture_archive_tree="$1"
	fixture_archive_file="$2"
	tar -czf "$fixture_archive_file" -C "$fixture_archive_tree" etc
}

run_valid_policy_smoke() {
	valid_work_dir="$1/valid-policy"
	mkdir -p "$valid_work_dir/source"
	write_valid_tree "$valid_work_dir/source"
	make_archive "$valid_work_dir/source" "$valid_work_dir/backup.tar.gz"
	valid_out_file="$valid_work_dir/run.out"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_IMPORT_TEST_MODE=1 \
	OWRT_IMPORT_TEST_MEM_AVAILABLE=1073741824 TMPDIR="$valid_work_dir" \
	UI_LIB="$UI_LIB" CONFIG_IMPORT_LIB="$IMPORT_LIB" sh -eu -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		initial_umask="$(umask)"
		config_import_prepare_file "$2/backup.tar.gz"
		test "$(umask)" = "$initial_umask"
		config_import_prepare_policy config-only
		printf "policy=%s members=%s network=%s hash=%s\n" \
			"$CONFIG_IMPORT_POLICY" "$CONFIG_IMPORT_MEMBER_COUNT" \
			"$CONFIG_IMPORT_HAS_NETWORK" "$CONFIG_IMPORT_SHA256"
		test -f "$CONFIG_IMPORT_APPLY_DIR/etc/config/network"
		test -f "$CONFIG_IMPORT_APPLY_DIR/etc/config/system"
		test ! -e "$CONFIG_IMPORT_APPLY_DIR/etc/shadow"
		config_import_prepare_policy full
		test -f "$CONFIG_IMPORT_APPLY_DIR/etc/shadow"
		test ! -e "$CONFIG_IMPORT_APPLY_DIR/etc/owrt-installer/interface-map"
		test ! -e "$CONFIG_IMPORT_APPLY_DIR/etc/uci-defaults/98-installer-network"
		test ! -e "$CONFIG_IMPORT_APPLY_DIR/etc/openwrt-installer-release"
		printf "full_policy=%s\n" "$CONFIG_IMPORT_POLICY"
		cleanup
	' sh "$INSTALLER" "$valid_work_dir" > "$valid_out_file" 2>&1 || fail "Valid config import policy smoke failed"

	assert_contains "$valid_out_file" "policy=config-only"
	assert_contains "$valid_out_file" "network=1"
	assert_contains "$valid_out_file" "full_policy=full"
	grep -Eq 'hash=[0-9a-f]{64}' "$valid_out_file" || fail "RAM archive SHA-256 was not reported"
	assert_not_exists "$valid_work_dir/owrt-import.leftover"
}

run_usb_scan_smoke() {
	scan_work_dir="$1/usb-scan"
	mkdir -p "$scan_work_dir/usb/backups/daily" "$scan_work_dir/usb-second/export"
	write_valid_tree "$scan_work_dir/source"
	make_archive "$scan_work_dir/source" "$scan_work_dir/usb/backups/daily/router-backup.tar.gz"
	cp "$scan_work_dir/usb/backups/daily/router-backup.tar.gz" "$scan_work_dir/usb/other.tgz"
	cp "$scan_work_dir/usb/backups/daily/router-backup.tar.gz" \
		"$scan_work_dir/usb-second/export/second-router.tar.gz"
	printf '%s|%s|%s|%s|%s\n' \
		"/dev/test-usb1" "vfat" "16777216" "TEST-USB" "$scan_work_dir/usb" \
		"/dev/test-usb2" "ext4" "33554432" "SECOND-USB" "$scan_work_dir/usb-second" \
		> "$scan_work_dir/partitions.list"
	scan_out_file="$scan_work_dir/run.out"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_IMPORT_TEST_MODE=1 \
	OWRT_IMPORT_TEST_PARTITIONS_FILE="$scan_work_dir/partitions.list" TMPDIR="$scan_work_dir" \
	UI_LIB="$UI_LIB" CONFIG_IMPORT_LIB="$IMPORT_LIB" sh -eu -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		TARGET=/dev/test-target
		config_import_enumerate_partitions
		config_import_scan_archives
		cat "$CONFIG_IMPORT_PARTITION_LIST"
		cat "$CONFIG_IMPORT_ARCHIVE_LIST"
		cleanup
	' sh "$INSTALLER" "$scan_work_dir" > "$scan_out_file" 2>&1 || fail "USB archive scan smoke failed"

	assert_contains "$scan_out_file" "/dev/test-usb1|vfat|16777216|TEST-USB"
	assert_contains "$scan_out_file" "/dev/test-usb2|ext4|33554432|SECOND-USB"
	assert_contains "$scan_out_file" "backups/daily/router-backup.tar.gz"
	assert_contains "$scan_out_file" "other.tgz"
	assert_contains "$scan_out_file" "export/second-router.tar.gz"
}

run_copy_before_unmount_smoke() {
	copy_work_dir="$1/copy-before-unmount"
	mkdir -p "$copy_work_dir/source"
	write_valid_tree "$copy_work_dir/source"
	make_archive "$copy_work_dir/source" "$copy_work_dir/backup.tar.gz"
	copy_out_file="$copy_work_dir/run.out"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_IMPORT_TEST_MODE=1 \
	OWRT_IMPORT_TEST_MEM_AVAILABLE=1073741824 TMPDIR="$copy_work_dir" \
	UI_LIB="$UI_LIB" CONFIG_IMPORT_LIB="$IMPORT_LIB" sh -eu -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		unmount_calls=0
		config_import_unmount_source() {
			unmount_calls=$((unmount_calls + 1))
			return 0
		}
		CONFIG_IMPORT_MOUNTED=1
		CONFIG_IMPORT_MOUNTDIR="$2/source"
		config_import_copy_archive_to_ram "$2/backup.tar.gz"
		test "$unmount_calls" -eq 0
		test -s "$CONFIG_IMPORT_ARCHIVE"
		printf "copy_before_unmount=ok\n"
		CONFIG_IMPORT_MOUNTED=0
		config_import_clear_ram_workspace
		cleanup
	' sh "$INSTALLER" "$copy_work_dir" > "$copy_out_file" 2>&1 ||
		fail "RAM copy happened after source unmount"

	assert_contains "$copy_out_file" "copy_before_unmount=ok"
}

run_read_only_mount_smoke() {
	mount_work_dir="$1/read-only-mount"
	mkdir -p "$mount_work_dir/bin"
	# shellcheck disable=SC2016 # The fake command records its runtime arguments.
	printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> "$MOUNT_ARGS_FILE"' \
		> "$mount_work_dir/bin/mount"
	printf '%s\n' '#!/bin/sh' 'exit 0' > "$mount_work_dir/bin/umount"
	chmod +x "$mount_work_dir/bin/mount" "$mount_work_dir/bin/umount"

	PATH="$mount_work_dir/bin:$PATH" MOUNT_ARGS_FILE="$mount_work_dir/mount.args" \
	OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$mount_work_dir" \
	UI_LIB="$UI_LIB" CONFIG_IMPORT_LIB="$IMPORT_LIB" sh -eu -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		config_import_mount_source /dev/test-ext4 ext4
		config_import_unmount_source
		config_import_mount_source /dev/test-vfat vfat
		config_import_unmount_source
		config_import_mount_source /dev/test-ntfs ntfs
		config_import_unmount_source
		cleanup
	' sh "$INSTALLER" "$mount_work_dir" > "$mount_work_dir/run.out" 2>&1 ||
		fail "Read-only mount option smoke failed"

	assert_contains "$mount_work_dir/mount.args" \
		"-t ext4 -o ro,noload,nosuid,nodev,noexec /dev/test-ext4"
	assert_contains "$mount_work_dir/mount.args" \
		"-t vfat -o ro,nosuid,nodev,noexec /dev/test-vfat"
	assert_contains "$mount_work_dir/mount.args" \
		"-t ntfs3 -o ro,nosuid,nodev,noexec /dev/test-ntfs"
}

run_installed_apply_smoke() {
	apply_work_dir="$1/installed-apply"
	mkdir -p "$apply_work_dir/source" "$apply_work_dir/target/etc/uci-defaults" \
		"$apply_work_dir/outside/config" "$apply_work_dir/bin"
	write_valid_tree "$apply_work_dir/source"
	make_archive "$apply_work_dir/source" "$apply_work_dir/backup.tar.gz"
	printf '%s\n' 'outside-must-not-change' > "$apply_work_dir/outside/config/sentinel"
	ln -s "$apply_work_dir/outside/config" "$apply_work_dir/target/etc/config"
	printf '%s\n' '#!/bin/sh' 'exit 0' > "$apply_work_dir/bin/mount"
	printf '%s\n' '#!/bin/sh' 'exit 0' > "$apply_work_dir/bin/umount"
	printf '%s\n' '#!/bin/sh' 'exit 0' > "$apply_work_dir/bin/sync"
	chmod +x "$apply_work_dir/bin/mount" "$apply_work_dir/bin/umount" "$apply_work_dir/bin/sync"
	printf '%s\n' '#!/bin/sh' 'exit 0' > "$apply_work_dir/network-applier"
	chmod +x "$apply_work_dir/network-applier"
	apply_out_file="$apply_work_dir/run.out"

	PATH="$apply_work_dir/bin:$PATH" OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_IMPORT_TEST_MODE=1 \
	OWRT_IMPORT_TEST_MEM_AVAILABLE=1073741824 TMPDIR="$apply_work_dir" \
	UI_LIB="$UI_LIB" CONFIG_IMPORT_LIB="$IMPORT_LIB" sh -eu -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		TARGET_MOUNT="$2/target"
		NETWORK_APPLIER="$2/network-applier"
		INSTALL_MODE=import
		NETWORK_SOURCE=imported
		SKIP_NETWORK=1
		PAYLOAD_SHA256=payload-sha
		PAYLOAD_VERSION=25.12.5
		PAYLOAD_SOURCE_ID=embedded
		PAYLOAD_FILENAME=target.img.gz
		PAYLOAD_IMAGE_TYPE=ext4-combined-efi
		PAYLOAD_BOOT_MODE=BIOS/UEFI
		PAYLOAD_URL=offline
		config_import_prepare_file "$2/backup.tar.gz"
		config_import_prepare_policy full
		write_installed_config /dev/fake-root /dev/fake-target
		cleanup
	' sh "$INSTALLER" "$apply_work_dir" > "$apply_out_file" 2>&1 || fail "Installed config import apply smoke failed"

	assert_contains "$apply_work_dir/target/etc/config/network" "br-imported"
	[ ! -L "$apply_work_dir/target/etc/config" ] || fail "Imported config directory remained a target symlink"
	assert_contains "$apply_work_dir/outside/config/sentinel" "outside-must-not-change"
	assert_not_exists "$apply_work_dir/outside/config/network"
	assert_not_exists "$apply_work_dir/target/etc/owrt-installer/interface-map"
	assert_not_exists "$apply_work_dir/target/etc/uci-defaults/98-installer-network"
	assert_contains "$apply_work_dir/target/etc/openwrt-installer-release" "install_mode=import"
	assert_contains "$apply_work_dir/target/etc/openwrt-installer-release" "network_source=imported"
	assert_contains "$apply_work_dir/target/etc/openwrt-installer-release" "config_import_policy=full"
	assert_contains "$apply_work_dir/target/etc/openwrt-installer-release" "lan_ip=imported"
	assert_contains "$apply_work_dir/target/etc/openwrt-installer-release" "wan_proto=imported"
	grep -Eq '^config_import_sha256=[0-9a-f]{64}$' \
		"$apply_work_dir/target/etc/openwrt-installer-release" || fail "Installed metadata lacks import SHA-256"
}

run_clean_metadata_smoke() {
	clean_work_dir="$1/clean-metadata"
	mkdir -p "$clean_work_dir/target/etc" "$clean_work_dir/bin"
	for clean_command in mount umount sync; do
		printf '%s\n' '#!/bin/sh' 'exit 0' > "$clean_work_dir/bin/$clean_command"
		chmod +x "$clean_work_dir/bin/$clean_command"
	done

	PATH="$clean_work_dir/bin:$PATH" OWRT_INSTALL_TEST_SOURCE_ONLY=1 \
	TMPDIR="$clean_work_dir" UI_LIB="$UI_LIB" CONFIG_IMPORT_LIB="$IMPORT_LIB" sh -eu -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		TARGET_MOUNT="$2/target"
		NETWORK_APPLIER="$2/missing-network-applier"
		INSTALL_MODE=clean
		NETWORK_SOURCE=defaults
		SKIP_NETWORK=1
		PAYLOAD_SHA256=payload-sha
		PAYLOAD_VERSION=25.12.5
		PAYLOAD_SOURCE_ID=embedded
		PAYLOAD_FILENAME=target.img.gz
		PAYLOAD_IMAGE_TYPE=ext4-combined-efi
		PAYLOAD_BOOT_MODE=BIOS/UEFI
		PAYLOAD_URL=offline
		write_installed_config /dev/fake-root /dev/fake-target
		cleanup
	' sh "$INSTALLER" "$clean_work_dir" > "$clean_work_dir/run.out" 2>&1 ||
		fail "Clean-install metadata smoke failed"

	assert_contains "$clean_work_dir/target/etc/openwrt-installer-release" "install_mode=clean"
	assert_contains "$clean_work_dir/target/etc/openwrt-installer-release" "network_source=defaults"
	assert_contains "$clean_work_dir/target/etc/openwrt-installer-release" "config_import_source=none"
	assert_contains "$clean_work_dir/target/etc/openwrt-installer-release" "config_import_sha256=none"
	assert_contains "$clean_work_dir/target/etc/openwrt-installer-release" "config_import_policy=none"
}

run_reject_archive() {
	name="$1"
	archive="$2"
	reject_work_dir="$3/reject-$name"
	mkdir -p "$reject_work_dir"
	reject_out_file="$reject_work_dir/run.out"

	set +e
	OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_IMPORT_TEST_MODE=1 \
	OWRT_IMPORT_TEST_MEM_AVAILABLE=1073741824 TMPDIR="$reject_work_dir" \
	UI_LIB="$UI_LIB" CONFIG_IMPORT_LIB="$IMPORT_LIB" sh -u -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		if config_import_prepare_file "$3"; then
			printf "unexpected-success\n"
			cleanup
			exit 0
		fi
		printf "error=%s\n" "$CONFIG_IMPORT_ERROR"
		cleanup
		exit 7
	' sh "$INSTALLER" "$reject_work_dir" "$archive" > "$reject_out_file" 2>&1
	status=$?
	set -e
	[ "$status" -eq 7 ] || fail "$name archive rejection exited with $status"
	assert_contains "$reject_out_file" "error="
	if find "$reject_work_dir" -maxdepth 1 -type d -name 'owrt-import.*' -print -quit | grep . >/dev/null 2>&1; then
		fail "$name rejection left an import workspace"
	fi
}

run_rejection_matrix() {
	rejection_root="$1/rejections"
	mkdir -p "$rejection_root/base/etc/config"
	printf '%s\n' "config system 'system'" > "$rejection_root/base/etc/config/system"

	mkdir -p "$rejection_root/symlink/etc/config"
	printf '%s\n' "config system 'system'" > "$rejection_root/symlink/etc/config/system"
	ln -s /etc/shadow "$rejection_root/symlink/etc/config/escape"
	make_archive "$rejection_root/symlink" "$rejection_root/symlink.tar.gz"
	run_reject_archive symlink "$rejection_root/symlink.tar.gz" "$1"

	mkdir -p "$rejection_root/hardlink/etc/config"
	printf '%s\n' "config system 'system'" > "$rejection_root/hardlink/etc/config/system"
	ln "$rejection_root/hardlink/etc/config/system" "$rejection_root/hardlink/etc/config/system-copy"
	make_archive "$rejection_root/hardlink" "$rejection_root/hardlink.tar.gz"
	run_reject_archive hardlink "$rejection_root/hardlink.tar.gz" "$1"

	mkdir -p "$rejection_root/fifo/etc/config"
	printf '%s\n' "config system 'system'" > "$rejection_root/fifo/etc/config/system"
	mkfifo "$rejection_root/fifo/etc/config/pipe"
	make_archive "$rejection_root/fifo" "$rejection_root/fifo.tar.gz"
	run_reject_archive fifo "$rejection_root/fifo.tar.gz" "$1"

	mkdir -p "$rejection_root/setuid/etc/config"
	printf '%s\n' "config system 'system'" > "$rejection_root/setuid/etc/config/system"
	printf '%s\n' '#!/bin/sh' > "$rejection_root/setuid/etc/config/helper"
	chmod 4755 "$rejection_root/setuid/etc/config/helper"
	make_archive "$rejection_root/setuid" "$rejection_root/setuid.tar.gz"
	run_reject_archive setuid "$rejection_root/setuid.tar.gz" "$1"

	tar -czf "$rejection_root/absolute.tar.gz" \
		--transform='s|^etc/config/system$|/etc/config/system|' \
		-C "$rejection_root/base" etc
	run_reject_archive absolute "$rejection_root/absolute.tar.gz" "$1"

	mkdir -p "$rejection_root/newline/etc/config"
	printf '%s\n' "config system 'system'" > "$rejection_root/newline/etc/config/system"
	newline_path="$(printf '%s\n%s' line break)"
	printf '%s\n' rejected > "$rejection_root/newline/etc/config/$newline_path"
	make_archive "$rejection_root/newline" "$rejection_root/newline.tar.gz"
	run_reject_archive newline "$rejection_root/newline.tar.gz" "$1"

	printf '%s\n' 'escape' > "$rejection_root/safe"
	tar -czf "$rejection_root/traversal.tar.gz" -C "$rejection_root/base" etc \
		--transform='s|^safe$|etc/../escape|' -C "$rejection_root" safe
	run_reject_archive traversal "$rejection_root/traversal.tar.gz" "$1"

	tar -cf "$rejection_root/duplicate.tar" -C "$rejection_root/base" etc
	tar -rf "$rejection_root/duplicate.tar" -C "$rejection_root/base" etc/config/system
	gzip -c "$rejection_root/duplicate.tar" > "$rejection_root/duplicate.tar.gz"
	run_reject_archive duplicate "$rejection_root/duplicate.tar.gz" "$1"

	printf '%s\n' 'not a gzip stream' > "$rejection_root/corrupt.tar.gz"
	run_reject_archive corrupt "$rejection_root/corrupt.tar.gz" "$1"

	mkdir -p "$rejection_root/nested-config/etc/config/unsupported"
	printf '%s\n' "config system 'system'" > "$rejection_root/nested-config/etc/config/system"
	printf '%s\n' rejected > "$rejection_root/nested-config/etc/config/unsupported/value"
	make_archive "$rejection_root/nested-config" "$rejection_root/nested-config.tar.gz"
	run_reject_archive nested-config "$rejection_root/nested-config.tar.gz" "$1"
}

run_resource_limit_smoke() {
	limit_work_dir="$1/resource-limits"
	mkdir -p "$limit_work_dir/source/etc/config"
	printf '%04096d\n' 0 > "$limit_work_dir/source/etc/config/large"
	make_archive "$limit_work_dir/source" "$limit_work_dir/large.tar.gz"
	limit_out_file="$limit_work_dir/run.out"

	set +e
	OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_IMPORT_TEST_MODE=1 \
	OWRT_IMPORT_TEST_MEM_AVAILABLE=1073741824 OWRT_IMPORT_MAX_MEMBER_BYTES=64 \
	TMPDIR="$limit_work_dir" UI_LIB="$UI_LIB" CONFIG_IMPORT_LIB="$IMPORT_LIB" sh -u -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		config_import_prepare_file "$2/large.tar.gz" || {
			printf "error=%s\n" "$CONFIG_IMPORT_ERROR"
			exit 9
		}
	' sh "$INSTALLER" "$limit_work_dir" > "$limit_out_file" 2>&1
	status=$?
	set -e
	[ "$status" -eq 9 ] || fail "Oversized member gate exited with $status"
	assert_contains "$limit_out_file" "unsafe types, modes, or resource sizes"

	set +e
	OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_IMPORT_TEST_MODE=1 \
	OWRT_IMPORT_TEST_MEM_AVAILABLE=1 TMPDIR="$limit_work_dir" \
	UI_LIB="$UI_LIB" CONFIG_IMPORT_LIB="$IMPORT_LIB" sh -u -c '
		. "$1"
		INSTALL_LOG="$2/install-low-memory.log"
		config_import_prepare_file "$2/large.tar.gz" || {
			printf "error=%s\n" "$CONFIG_IMPORT_ERROR"
			exit 8
		}
	' sh "$INSTALLER" "$limit_work_dir" > "$limit_work_dir/low-memory.out" 2>&1
	status=$?
	set -e
	[ "$status" -eq 8 ] || fail "Low-memory gate exited with $status"
	assert_contains "$limit_work_dir/low-memory.out" "Not enough free RAM"

	set +e
	OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_IMPORT_TEST_MODE=1 \
	OWRT_IMPORT_TEST_MEM_AVAILABLE=1073741824 OWRT_IMPORT_MAX_MEMBERS=2 \
	TMPDIR="$limit_work_dir" UI_LIB="$UI_LIB" CONFIG_IMPORT_LIB="$IMPORT_LIB" sh -u -c '
		. "$1"
		INSTALL_LOG="$2/install-member-count.log"
		config_import_prepare_file "$2/large.tar.gz" || {
			printf "error=%s\n" "$CONFIG_IMPORT_ERROR"
			exit 10
		}
	' sh "$INSTALLER" "$limit_work_dir" > "$limit_work_dir/member-count.out" 2>&1
	status=$?
	set -e
	[ "$status" -eq 10 ] || fail "Member-count gate exited with $status"
	assert_contains "$limit_work_dir/member-count.out" "unsafe types, modes, or resource sizes"

	set +e
	OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_IMPORT_TEST_MODE=1 \
	OWRT_IMPORT_TEST_MEM_AVAILABLE=1073741824 OWRT_IMPORT_MAX_COMPRESSED_BYTES=1 \
	TMPDIR="$limit_work_dir" UI_LIB="$UI_LIB" CONFIG_IMPORT_LIB="$IMPORT_LIB" sh -u -c '
		. "$1"
		INSTALL_LOG="$2/install-compressed-size.log"
		config_import_prepare_file "$2/large.tar.gz" || {
			printf "error=%s\n" "$CONFIG_IMPORT_ERROR"
			exit 11
		}
	' sh "$INSTALLER" "$limit_work_dir" > "$limit_work_dir/compressed-size.out" 2>&1
	status=$?
	set -e
	[ "$status" -eq 11 ] || fail "Compressed-size gate exited with $status"
	assert_contains "$limit_work_dir/compressed-size.out" "compressed limit"
}

run_signal_cleanup_smoke() {
	signal_work_dir="$1/signal-cleanup"
	mkdir -p "$signal_work_dir/source"
	write_valid_tree "$signal_work_dir/source"
	make_archive "$signal_work_dir/source" "$signal_work_dir/backup.tar.gz"

	set +e
	OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_IMPORT_TEST_MODE=1 \
	OWRT_IMPORT_TEST_MEM_AVAILABLE=1073741824 TMPDIR="$signal_work_dir" \
	UI_LIB="$UI_LIB" CONFIG_IMPORT_LIB="$IMPORT_LIB" sh -u -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		config_import_prepare_file "$2/backup.tar.gz"
		printf "workspace=%s\n" "$CONFIG_IMPORT_WORKDIR"
		kill -HUP "$$"
		exit 99
	' sh "$INSTALLER" "$signal_work_dir" > "$signal_work_dir/run.out" 2>&1
	status=$?
	set -e
	[ "$status" -eq 130 ] || fail "HUP cleanup smoke exited with $status"
	assert_contains "$signal_work_dir/run.out" "workspace=$signal_work_dir/owrt-import."
	if find "$signal_work_dir" -maxdepth 1 -type d -name 'owrt-import.*' -print -quit | grep . >/dev/null 2>&1; then
		fail "HUP cleanup left an import workspace"
	fi
}

[ -r "$INSTALLER" ] || fail "Installer not found: $INSTALLER"
[ -r "$IMPORT_LIB" ] || fail "Import library not found: $IMPORT_LIB"

suite_work_dir="$(mktemp -d "$TMPDIR/owrt-config-import-smoke.XXXXXX")"
trap 'rm -rf "$suite_work_dir"' EXIT INT TERM

run_valid_policy_smoke "$suite_work_dir"
run_usb_scan_smoke "$suite_work_dir"
run_copy_before_unmount_smoke "$suite_work_dir"
run_read_only_mount_smoke "$suite_work_dir"
run_installed_apply_smoke "$suite_work_dir"
run_clean_metadata_smoke "$suite_work_dir"
run_rejection_matrix "$suite_work_dir"
run_resource_limit_smoke "$suite_work_dir"
run_signal_cleanup_smoke "$suite_work_dir"

printf 'Configuration import smoke tests passed.\n'
