#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INSTALLER="$PROJECT_DIR/files-installer/usr/sbin/owrt-install"
UI_LIB="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-ui"
IMPORT_LIB="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-config-import"
STORAGE_LIB="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-storage"
PAYLOAD_FILE="$PROJECT_DIR/files-installer/usr/share/owrt-installer/target.img.gz"
MANIFEST_FILE="$PROJECT_DIR/files-installer/usr/share/owrt-installer/manifest.json"
TMPDIR="${TMPDIR:-/tmp}"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	file="$1"
	pattern="$2"
	grep -F -- "$pattern" "$file" >/dev/null 2>&1 || {
		sed -n '1,240p' "$file" >&2 || true
		fail "Expected output to contain: $pattern"
	}
}

run_layout_smoke() {
	work_dir="$1/layout"
	mkdir -p "$work_dir"
	out_file="$work_dir/run.out"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_STORAGE_TEST_MODE=1 \
	OWRT_STORAGE_TEST_DISK_SECTORS=134217728 \
	OWRT_STORAGE_TEST_LOGICAL_SECTOR_SIZE=512 TMPDIR="$work_dir" \
	UI_LIB="$UI_LIB" CONFIG_IMPORT_LIB="$IMPORT_LIB" STORAGE_LIB="$STORAGE_LIB" \
	sh -eu -c '
		. "$1"
		PAYLOAD="$2"
		MANIFEST="$3"
		INSTALL_LOG="$4/install.log"
		payload_size="$(json_value payload_uncompressed_size)"
		storage_inspect_payload_layout "$PAYLOAD" "$payload_size" uefi
		printf "gpt=%s boot=%s-%s root=%s-%s image_mib=%s\n" \
			"$STORAGE_TABLE_TYPE" "$STORAGE_BOOT_START_SECTOR" "$STORAGE_BOOT_END_SECTOR" \
			"$STORAGE_ROOT_START_SECTOR" "$STORAGE_ROOT_IMAGE_END_SECTOR" "$STORAGE_ROOT_IMAGE_MIB"
		storage_prepare_target_geometry /dev/testdisk
		printf "fill=end:%s root_mib:%s free:%s\n" \
			"$STORAGE_ROOT_TARGET_END_SECTOR" "$STORAGE_ROOT_TARGET_MIB" "$STORAGE_UNALLOCATED_MIB"
		storage_parse_size_mib "8 GiB"
		storage_calculate_layout bounded "$STORAGE_PARSED_SIZE_MIB"
		printf "bounded=mib:%s end:%s free:%s\n" \
			"$STORAGE_ROOT_TARGET_MIB" "$STORAGE_ROOT_TARGET_END_SECTOR" "$STORAGE_UNALLOCATED_MIB"
		storage_calculate_layout image
		printf "image=end:%s root_mib:%s\n" "$STORAGE_ROOT_TARGET_END_SECTOR" "$STORAGE_ROOT_TARGET_MIB"
		if storage_calculate_layout bounded 128; then exit 21; fi
		printf "small_rejected=%s\n" "$STORAGE_ERROR"
		if storage_parse_size_mib "12.5 GiB"; then exit 22; fi
		printf "fraction_rejected=yes\n"
		OWRT_STORAGE_TEST_LOGICAL_SECTOR_SIZE=4096
		if storage_prepare_target_geometry /dev/testdisk; then exit 23; fi
		printf "4kn_rejected=%s\n" "$STORAGE_ERROR"
		cleanup
	' sh "$INSTALLER" "$PAYLOAD_FILE" "$MANIFEST_FILE" "$work_dir" > "$out_file" 2>&1 ||
		fail "Storage geometry smoke failed"

	assert_contains "$out_file" "gpt=gpt boot=512-33279 root=33280-557567 image_mib=256"
	assert_contains "$out_file" "fill=end:134217694"
	assert_contains "$out_file" "bounded=mib:8192 end:16810495"
	assert_contains "$out_file" "image=end:557567 root_mib:256"
	assert_contains "$out_file" "small_rejected="
	assert_contains "$out_file" "fraction_rejected=yes"
	assert_contains "$out_file" "4kn_rejected=/dev/testdisk uses 4096-byte logical sectors"
}

run_mbr_layout_smoke() {
	work_dir="$1/mbr"
	mkdir -p "$work_dir"
	raw_file="$work_dir/mbr.img"
	gzip_file="$work_dir/mbr.img.gz"
	bad_raw_file="$work_dir/mbr-bad-ext4.img"
	bad_gzip_file="$work_dir/mbr-bad-ext4.img.gz"
	extra_raw_file="$work_dir/mbr-extra-partition.img"
	extra_gzip_file="$work_dir/mbr-extra-partition.img.gz"
	out_file="$work_dir/run.out"

	command -v sfdisk >/dev/null 2>&1 || fail "sfdisk is required for MBR layout smoke"
	truncate -s 64M "$raw_file"
	printf '%s\n' \
		'label: dos' \
		'unit: sectors' \
		'' \
		'start=2048, size=8192, type=83, bootable' \
		'start=10240, size=65536, type=83' |
		sfdisk "$raw_file" >/dev/null 2>&1
	# Minimal ext4 superblock fields used by the pre-ERASE payload invariant:
	# 8192 x 4096-byte blocks exactly fill the 65536-sector root partition.
	printf '\000\040\000\000' | dd of="$raw_file" bs=1 seek=5243908 conv=notrunc status=none
	printf '\002\000\000\000' | dd of="$raw_file" bs=1 seek=5243928 conv=notrunc status=none
	printf '\123\357' | dd of="$raw_file" bs=1 seek=5243960 conv=notrunc status=none
	gzip -c "$raw_file" > "$gzip_file"
	cp "$raw_file" "$bad_raw_file"
	printf '\377\037\000\000' | dd of="$bad_raw_file" bs=1 seek=5243908 conv=notrunc status=none
	gzip -c "$bad_raw_file" > "$bad_gzip_file"
	truncate -s 64M "$extra_raw_file"
	printf '%s\n' \
		'label: dos' \
		'unit: sectors' \
		'' \
		'start=2048, size=8192, type=83, bootable' \
		'start=10240, size=65536, type=83' \
		'start=80000, size=8192, type=83' |
		sfdisk "$extra_raw_file" >/dev/null 2>&1
	printf '\000\040\000\000' | dd of="$extra_raw_file" bs=1 seek=5243908 conv=notrunc status=none
	printf '\002\000\000\000' | dd of="$extra_raw_file" bs=1 seek=5243928 conv=notrunc status=none
	printf '\123\357' | dd of="$extra_raw_file" bs=1 seek=5243960 conv=notrunc status=none
	gzip -c "$extra_raw_file" > "$extra_gzip_file"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$work_dir" UI_LIB="$UI_LIB" \
	CONFIG_IMPORT_LIB="$IMPORT_LIB" STORAGE_LIB="$STORAGE_LIB" sh -eu -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		storage_inspect_payload_layout "$3" 67108864 bios
		printf "mbr=%s boot=%s-%s root=%s-%s sectors=%s\n" \
			"$STORAGE_TABLE_TYPE" "$STORAGE_BOOT_START_SECTOR" "$STORAGE_BOOT_END_SECTOR" \
			"$STORAGE_ROOT_START_SECTOR" "$STORAGE_ROOT_IMAGE_END_SECTOR" "$STORAGE_ROOT_IMAGE_SECTORS"
		if storage_inspect_payload_layout "$4" 67108864 bios; then exit 30; fi
		printf "ext4_rejected=%s\n" "$STORAGE_ERROR"
		storage_cleanup
		if storage_inspect_payload_layout "$3" 67108864 uefi; then exit 31; fi
		printf "mode_rejected=%s\n" "$STORAGE_ERROR"
		storage_cleanup
		if storage_inspect_payload_layout "$5" 67108864 bios; then exit 32; fi
		printf "extra_rejected=%s\n" "$STORAGE_ERROR"
		cleanup
	' sh "$INSTALLER" "$work_dir" "$gzip_file" "$bad_gzip_file" "$extra_gzip_file" > "$out_file" 2>&1 ||
		fail "MBR layout smoke failed"

	assert_contains "$out_file" "mbr=dos boot=2048-10239 root=10240-75775 sectors=65536"
	assert_contains "$out_file" "ext4_rejected=The payload ext4 filesystem does not fill partition 2."
	assert_contains "$out_file" "mode_rejected=The selected UEFI payload does not use the expected GPT layout."
	assert_contains "$out_file" "extra_rejected=The payload contains unexpected partitions."
}

write_existing_openwrt() {
	root="$1"
	mkdir -p "$root/etc/config" "$root/etc/dropbear" "$root/etc/uci-defaults" "$root/etc/owrt-installer" \
		"$root/lib/apk/db"
	chmod 0700 "$root/etc/dropbear"
	cat > "$root/etc/openwrt_release" <<'EOF'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.3'
DISTRIB_TARGET='x86/64'
EOF
	printf '%s\n' "config interface 'lan'" "option proto 'static'" > "$root/etc/config/network"
	printf '%s\n' "config system 'system'" "option hostname 'rescued-router'" > "$root/etc/config/system"
	printf '%s\n' 'stale installer state' > "$root/etc/openwrt-installer-release"
	printf '%s\n' 'stale interface map' > "$root/etc/owrt-installer/interface-map"
	printf '%s\n' '#!/bin/sh' > "$root/etc/uci-defaults/98-installer-network"
	printf '%s\n' 'private host key fixture' > "$root/etc/dropbear/dropbear_rsa_host_key"
	chmod 0600 "$root/etc/dropbear/dropbear_rsa_host_key"
	ln -s /tmp/not-followed "$root/etc/config/unsafe-link"
	mkfifo "$root/etc/config/unsafe-fifo"
	printf '%s\n' 'hardlinked data' > "$root/etc/config/hardlink-source"
	ln "$root/etc/config/hardlink-source" "$root/etc/config/hardlink-copy"
	printf '%s\n' 'P:base-files' 'V:1' '' 'P:luci-ssl' 'V:1' > "$root/lib/apk/db/installed"
}

run_probe_rescue_smoke() {
	work_dir="$1/rescue"
	root="$work_dir/existing"
	mkdir -p "$work_dir"
	write_existing_openwrt "$root"
	partitions="$work_dir/partitions.list"
	printf '%s\n' \
		'/dev/testdisk1|vfat|kernel||512|32768' \
		"/dev/testdisk2|ext4|rootfs|$root|33280|1048576" > "$partitions"
	out_file="$work_dir/run.out"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_STORAGE_TEST_MODE=1 \
	OWRT_STORAGE_TEST_PARTITIONS_FILE="$partitions" OWRT_IMPORT_TEST_MODE=1 \
	OWRT_IMPORT_TEST_MEM_AVAILABLE=1073741824 TMPDIR="$work_dir" UI_LIB="$UI_LIB" \
	CONFIG_IMPORT_LIB="$IMPORT_LIB" STORAGE_LIB="$STORAGE_LIB" sh -eu -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		TARGET=/dev/testdisk
		storage_probe_existing_openwrt
		printf "probe=%s rescue_ready=%s version=%s target=%s root=%s boot=%s mounted=%s\n" \
			"$STORAGE_EXISTING_FOUND" "$STORAGE_EXISTING_RESCUE_AVAILABLE" \
			"$STORAGE_EXISTING_VERSION" "$STORAGE_EXISTING_TARGET" \
			"$STORAGE_EXISTING_ROOT_PART" "$STORAGE_EXISTING_BOOT_PART" "$STORAGE_PROBE_MOUNTED"
		storage_prepare_rescue_snapshot config-only
		INSTALL_MODE=rescue
		printf "rescue=%s source=%s policy=%s network=%s skipped=%s packages=%s mounted=%s\n" \
			"$STORAGE_RESCUE_SCOPE" "$STORAGE_RESCUE_SOURCE_VERSION" "$CONFIG_IMPORT_POLICY" \
			"$CONFIG_IMPORT_HAS_NETWORK" "$STORAGE_RESCUE_SKIPPED" \
			"$STORAGE_RESCUE_PACKAGE_COUNT" "$STORAGE_PROBE_MOUNTED"
		grep -Fx base-files "$STORAGE_RESCUE_PACKAGE_LIST"
		grep -Fx luci-ssl "$STORAGE_RESCUE_PACKAGE_LIST"
		test -f "$CONFIG_IMPORT_APPLY_DIR/etc/config/network"
		test -f "$CONFIG_IMPORT_APPLY_DIR/etc/config/system"
		test ! -e "$CONFIG_IMPORT_APPLY_DIR/etc/config/unsafe-link"
		test ! -e "$CONFIG_IMPORT_APPLY_DIR/etc/config/unsafe-fifo"
		config_import_clear_workspace
		if ! storage_prepare_rescue_snapshot full; then
			printf "full_error=%s import_error=%s\n" "$STORAGE_ERROR" "$CONFIG_IMPORT_ERROR"
			tar -tzf "$STORAGE_RESCUE_WORKDIR/rescue.tar.gz" || true
			exit 41
		fi
		test ! -e "$CONFIG_IMPORT_APPLY_DIR/etc/openwrt-installer-release"
		test ! -e "$CONFIG_IMPORT_APPLY_DIR/etc/owrt-installer"
		test ! -e "$CONFIG_IMPORT_APPLY_DIR/etc/uci-defaults/98-installer-network"
		test -f "$CONFIG_IMPORT_APPLY_DIR/etc/config/hardlink-source"
		test -f "$CONFIG_IMPORT_APPLY_DIR/etc/config/hardlink-copy"
		test "$(stat -c %a "$CONFIG_IMPORT_APPLY_DIR/etc/dropbear")" = 700
		test "$(stat -c %a "$CONFIG_IMPORT_APPLY_DIR/etc/dropbear/dropbear_rsa_host_key")" = 600
		printf "full_rescue=ok policy=%s\n" "$CONFIG_IMPORT_POLICY"
		cleanup
	' sh "$INSTALLER" "$work_dir" > "$out_file" 2>&1 || {
		sed -n '1,260p' "$out_file" >&2 || true
		fail "Existing OpenWrt probe/rescue smoke failed"
	}

	assert_contains "$out_file" "probe=1 rescue_ready=1 version=25.12.3 target=x86/64 root=/dev/testdisk2 boot=/dev/testdisk1 mounted=0"
	assert_contains "$out_file" "rescue=config-only source=25.12.3 policy=config-only network=1 skipped=2 packages=2 mounted=0"
	assert_contains "$out_file" "full_rescue=ok policy=full"
}

run_probe_rejection_smoke() {
	work_dir="$1/rejections"
	valid_root="$work_dir/valid"
	forged_root="$work_dir/forged"
	newline_root="$work_dir/newline"
	oversize_root="$work_dir/oversize"
	partitions="$work_dir/partitions.list"
	out_file="$work_dir/run.out"
	mkdir -p "$work_dir"
	write_existing_openwrt "$valid_root"
	write_existing_openwrt "$newline_root"
	write_existing_openwrt "$oversize_root"
	mkdir -p "$forged_root/etc/config"
	cat > "$forged_root/etc/openwrt_release" <<EOF
DISTRIB_ID=\$(touch $work_dir/forged-executed)
DISTRIB_RELEASE='25.12.3'
DISTRIB_TARGET='x86/64'
EOF
	printf '%s\n' "config system 'system'" > "$forged_root/etc/config/system"
	printf '%s\n' 'unsafe name' > "$newline_root/etc/config/bad
name"
	truncate -s 33M "$oversize_root/etc/config/oversized"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 OWRT_STORAGE_TEST_MODE=1 \
	OWRT_STORAGE_TEST_PARTITIONS_FILE="$partitions" OWRT_IMPORT_TEST_MODE=1 \
	OWRT_IMPORT_TEST_MEM_AVAILABLE=1073741824 TMPDIR="$work_dir" UI_LIB="$UI_LIB" \
	CONFIG_IMPORT_LIB="$IMPORT_LIB" STORAGE_LIB="$STORAGE_LIB" sh -eu -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		TARGET=/dev/testdisk
		printf "/dev/testdisk2|ext4|rootfs|%s|33280|1048576\n" "$3" > "$4"
		if storage_probe_existing_openwrt; then exit 51; fi
		test ! -e "$2/forged-executed"
		printf "forged_release=rejected\n"

		printf "/dev/testdisk2|ext4|rootfs|%s|33280|1048576\n" "$5" > "$4"
		storage_probe_existing_openwrt
		OWRT_IMPORT_TEST_MEM_AVAILABLE=1024
		export OWRT_IMPORT_TEST_MEM_AVAILABLE
		if storage_prepare_rescue_snapshot config-only; then exit 52; fi
		printf "low_ram=%s mounted=%s\n" "$STORAGE_ERROR" "$STORAGE_PROBE_MOUNTED"
		OWRT_IMPORT_TEST_MEM_AVAILABLE=603979775
		export OWRT_IMPORT_TEST_MEM_AVAILABLE
		if storage_prepare_rescue_snapshot config-only; then exit 55; fi
		printf "peak_ram=%s mounted=%s\n" "$STORAGE_ERROR" "$STORAGE_PROBE_MOUNTED"
		OWRT_IMPORT_TEST_MEM_AVAILABLE=1073741824
		export OWRT_IMPORT_TEST_MEM_AVAILABLE

		printf "/dev/testdisk2|ext4|rootfs|%s|33280|1048576\n" "$6" > "$4"
		storage_probe_existing_openwrt
		if storage_prepare_rescue_snapshot config-only; then exit 53; fi
		printf "newline=%s mounted=%s\n" "$STORAGE_ERROR" "$STORAGE_PROBE_MOUNTED"
		config_import_clear_workspace

		printf "/dev/testdisk2|ext4|rootfs|%s|33280|1048576\n" "$7" > "$4"
		storage_probe_existing_openwrt
		if storage_prepare_rescue_snapshot config-only; then exit 54; fi
		printf "oversize=%s mounted=%s\n" "$STORAGE_ERROR" "$STORAGE_PROBE_MOUNTED"
		cleanup
	' sh "$INSTALLER" "$work_dir" "$forged_root" "$partitions" "$valid_root" \
		"$newline_root" "$oversize_root" > "$out_file" 2>&1 || {
		sed -n '1,260p' "$out_file" >&2 || true
		fail "Existing OpenWrt rejection smoke failed"
	}

	assert_contains "$out_file" "forged_release=rejected"
	assert_contains "$out_file" "low_ram=Not enough free RAM to rescue and validate the existing configuration safely. mounted=0"
	assert_contains "$out_file" "peak_ram=Not enough free RAM to rescue and validate the existing configuration safely. mounted=0"
	assert_contains "$out_file" "newline=The backup contains an unsafe or unsupported path. mounted=0"
	assert_contains "$out_file" "oversize=The existing configuration exceeds the RAM rescue limits. mounted=0"
}

run_read_only_probe_mount_smoke() {
	work_dir="$1/read-only"
	mkdir -p "$work_dir/bin"
	# shellcheck disable=SC2016 # This writes the fake command.
	printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> "$MOUNT_ARGS_FILE"' > "$work_dir/bin/mount"
	printf '%s\n' '#!/bin/sh' 'exit 0' > "$work_dir/bin/umount"
	chmod +x "$work_dir/bin/mount" "$work_dir/bin/umount"

	PATH="$work_dir/bin:$PATH" MOUNT_ARGS_FILE="$work_dir/mount.args" \
	OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$work_dir" UI_LIB="$UI_LIB" \
	CONFIG_IMPORT_LIB="$IMPORT_LIB" STORAGE_LIB="$STORAGE_LIB" sh -eu -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		storage_mount_probe /dev/testdisk2
		storage_unmount_probe
		cleanup
	' sh "$INSTALLER" "$work_dir" > "$work_dir/run.out" 2>&1 ||
		fail "Read-only existing-root mount smoke failed"
	assert_contains "$work_dir/mount.args" "-t ext4 -o ro,noload,nosuid,nodev,noexec /dev/testdisk2"
}

[ -r "$PAYLOAD_FILE" ] || fail "Embedded target payload is missing"
[ -r "$MANIFEST_FILE" ] || fail "Embedded target manifest is missing"

work_dir="$(mktemp -d "$TMPDIR/owrt-storage-rescue-smoke.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT INT TERM

run_layout_smoke "$work_dir"
run_mbr_layout_smoke "$work_dir"
run_probe_rescue_smoke "$work_dir"
run_probe_rejection_smoke "$work_dir"
run_read_only_probe_mount_smoke "$work_dir"

printf 'Storage geometry and existing OpenWrt rescue smoke tests passed.\n'
