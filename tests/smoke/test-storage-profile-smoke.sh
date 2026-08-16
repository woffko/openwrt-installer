#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INSTALLER="$PROJECT_DIR/files-installer/usr/sbin/owrt-install"
UI_LIB="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-ui"
STORAGE_LIB="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-storage"
GUARD="$PROJECT_DIR/files-target/etc/owrt-installer/upgrade-guard"
WRAPPER="$PROJECT_DIR/files-target/etc/owrt-installer/sysupgrade-wrapper"
GUARD_INSTALLER="$PROJECT_DIR/files-target/etc/owrt-installer/install-upgrade-guard"
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

create_chunked_gzip_wrapper() {
	wrapper_dir="$1"
	real_gzip="$2"
	mkdir -p "$wrapper_dir"
	cat > "$wrapper_dir/gzip" <<EOF
#!/bin/sh
case "\$1" in
	-t) exec "$real_gzip" "\$@" ;;
	-dc)
		"$real_gzip" "\$@" | {
			dd bs=1 count=1 2>/dev/null
			sleep 0.1
			cat
		}
		;;
	*) exec "$real_gzip" "\$@" ;;
esac
EOF
	chmod 0755 "$wrapper_dir/gzip"
}

run_geometry_smoke() {
	work_dir="$1/geometry"
	mkdir -p "$work_dir"
	out_file="$work_dir/run.out"
	OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$work_dir" UI_LIB="$UI_LIB" \
		STORAGE_LIB="$STORAGE_LIB" sh -eu -c '
			. "$1"
			STORAGE_TABLE_TYPE=gpt
			STORAGE_PAYLOAD_SECTOR_SIZE=512
			STORAGE_BOOT_START_SECTOR=512
			STORAGE_BOOT_END_SECTOR=33279
			STORAGE_BOOT_SECTORS=32768
			STORAGE_ROOT_START_SECTOR=33280
			STORAGE_ROOT_IMAGE_END_SECTOR=557567
			STORAGE_ROOT_IMAGE_SECTORS=524288
			STORAGE_ROOT_IMAGE_MIB=256
			STORAGE_DISK_SECTORS=41943040
			STORAGE_DISK_USABLE_END_SECTOR=41943006
			storage_configure_compatible_profile
			IFS="|" read -r number start end label mountpoint < "$STORAGE_DATA_LAYOUT_LIST"
			remaining=$((STORAGE_DISK_USABLE_END_SECTOR - start + 1))
			data_sectors=$((end - start + 1))
			expected=$(storage_align_down "$(storage_percent_floor "$remaining" 80)" 2048)
			test "$number" = 3
			test "$label" = owrt-data
			test "$mountpoint" = /mnt/data
			test "$STORAGE_ROOT_TARGET_END_SECTOR" = "$STORAGE_ROOT_IMAGE_END_SECTOR"
			test "$((start % 2048))" = 0
			test "$data_sectors" = "$expected"
			test "$STORAGE_RESERVED_SECTORS" -gt 0
			printf "compatible=root:%s data:%s reserve:%s start:%s\n" \
				"$STORAGE_ROOT_TARGET_SECTORS" "$data_sectors" "$STORAGE_RESERVED_SECTORS" "$start"

			storage_calculate_layout bounded 4096
			STORAGE_PROFILE=custom
			storage_add_data_partition_mib 1024 data-a /mnt/data-a
			storage_add_data_partition_mib 2048 data-b /srv/data-b
			printf "custom=count:%s total:%s reserve:%s numbers:%s\n" \
				"$STORAGE_DATA_PARTITION_COUNT" "$STORAGE_DATA_TOTAL_MIB" \
				"$STORAGE_RESERVED_MIB" "$(cut -d"|" -f1 "$STORAGE_DATA_LAYOUT_LIST" | tr "\n" ",")"
			if storage_add_data_partition_mib 1 data-b /mnt/duplicate; then exit 31; fi
			printf "duplicate=%s\n" "$STORAGE_ERROR"
			if storage_add_data_partition_mib 1 safe /etc/unsafe; then exit 32; fi
			printf "mount=%s\n" "$STORAGE_ERROR"

			STORAGE_TABLE_TYPE=dos
			storage_calculate_layout image
			STORAGE_PROFILE=custom
			storage_add_data_partition_mib 8 mbr-a /mnt/mbr-a
			storage_add_data_partition_mib 8 mbr-b /mnt/mbr-b
			if storage_add_data_partition_mib 8 mbr-c /mnt/mbr-c; then exit 33; fi
			printf "mbr_limit=%s\n" "$STORAGE_ERROR"
			cleanup
		' sh "$INSTALLER" > "$out_file" 2>&1 || fail "Storage profile geometry smoke failed"
	assert_contains "$out_file" "compatible=root:524288"
	assert_contains "$out_file" "custom=count:2 total:3072"
	assert_contains "$out_file" "numbers:3,4,"
	assert_contains "$out_file" "duplicate=Data partition label 'data-b' is already used."
	assert_contains "$out_file" "mount=Data mount points must be absolute paths below /mnt or /srv."
	assert_contains "$out_file" "mbr_limit=The selected partition table cannot contain another data partition."
}

run_target_metadata_smoke() {
	work_dir="$1/metadata"
	root="$work_dir/root"
	out_file="$work_dir/run.out"
	uci_calls="$work_dir/uci.calls"
	mkdir -p "$root/etc/config"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$work_dir" UI_LIB="$UI_LIB" \
		STORAGE_LIB="$STORAGE_LIB" sh -eu -c '
			. "$1"
			INSTALL_LOG="$2/install.log"
			UCI_CALLS="$4"
			STORAGE_PROFILE=custom
			STORAGE_TABLE_TYPE=gpt
			STORAGE_BOOT_START_SECTOR=512
			STORAGE_BOOT_END_SECTOR=33279
			STORAGE_BOOT_SECTORS=32768
			STORAGE_ROOT_START_SECTOR=33280
			STORAGE_ROOT_TARGET_END_SECTOR=1081855
			STORAGE_DATA_PARTITION_COUNT=2
			STORAGE_RESERVED_SECTORS=4096
			STORAGE_RESERVED_MIB=2
			STORAGE_DISCARD_STATUS=completed
			printf "%s\n" \
				"3|1083392|3180543|data-a|/mnt/data-a" \
				"4|3180544|7374847|data-b|/srv/data-b" > "$STORAGE_DATA_LAYOUT_LIST"
			uci() { printf "%s\n" "$*" >> "$UCI_CALLS"; }
			blkid() {
				field=""
				device=""
				while [ "$#" -gt 0 ]; do
					case "$1" in -s) field="$2"; shift 2 ;; *) device="$1"; shift ;; esac
				done
				case "$field:$device" in
					UUID:/dev/testdisk3) printf "%s\n" 11111111-1111-1111-1111-111111111111 ;;
					UUID:/dev/testdisk4) printf "%s\n" 22222222-2222-2222-2222-222222222222 ;;
					*) return 1 ;;
				esac
			}
			write_storage_target_config "$3" /dev/testdisk
			cleanup
		' sh "$INSTALLER" "$work_dir" "$root" "$uci_calls" > "$out_file" 2>&1 || {
			sed -n '1,240p' "$out_file" >&2 || true
			fail "Target storage metadata smoke failed"
		}

	assert_contains "$root/etc/config/owrt-installer" "option profile 'custom'"
	assert_contains "$root/etc/config/owrt-installer" "config data 'partition3'"
	assert_contains "$root/etc/config/owrt-installer" "option mountpoint '/srv/data-b'"
	assert_contains "$root/etc/owrt-installer/storage-layout" "schema=1"
	assert_contains "$root/etc/owrt-installer/storage-layout" \
		"data=4|3180544|7374847|data-b|/srv/data-b|22222222-2222-2222-2222-222222222222"
	assert_contains "$uci_calls" "set fstab.owrt_data_3.uuid=11111111-1111-1111-1111-111111111111"
	assert_contains "$uci_calls" "set fstab.owrt_data_4.target=/srv/data-b"
	assert_contains "$uci_calls" "set fstab.owrt_data_4.options=rw,noatime"
	assert_contains "$uci_calls" "commit fstab"
	[ -f "$root/etc/config/fstab" ] || fail "Missing target fstab was not created"
	[ -d "$root/mnt/data-a" ] || fail "Target /mnt/data-a was not created"
	[ -d "$root/srv/data-b" ] || fail "Target /srv/data-b was not created"
	[ "$(stat -c %a "$root/etc/owrt-installer/storage-layout")" = 600 ] ||
		fail "Target storage-layout metadata is not mode 0600"
}

write_mbr_image() {
	path="$1"
	root_sectors="$2"
	extra="${3:-0}"
	truncate -s 64M "$path"
	if [ "$extra" = 1 ]; then
		printf '%s\n' 'label: dos' 'unit: sectors' '' \
			'start=2048, size=8192, type=83, bootable' \
			"start=10240, size=$root_sectors, type=83" \
			'start=50000, size=4096, type=83' |
			sfdisk "$path" >/dev/null 2>&1
	else
		printf '%s\n' 'label: dos' 'unit: sectors' '' \
			'start=2048, size=8192, type=83, bootable' \
			"start=10240, size=$root_sectors, type=83" |
			sfdisk "$path" >/dev/null 2>&1
	fi
	printf '\123\357' | dd of="$path" bs=1 seek=$((10240 * 512 + 1080)) \
		conv=notrunc status=none
}

write_gpt_image() {
	path="$1"
	root_sectors="$2"
	truncate -s 320M "$path"
	printf '%s\n' 'label: gpt' 'unit: sectors' 'first-lba: 34' '' \
		'start=512, size=32768, type=L' \
		"start=33280, size=$root_sectors, type=L" |
		sfdisk "$path" >/dev/null 2>&1
	printf '\123\357' | dd of="$path" bs=1 seek=$((33280 * 512 + 1080)) \
		conv=notrunc status=none
}

run_guard_smoke() {
	work_dir="$1/guard"
	mkdir -p "$work_dir"
	metadata="$work_dir/metadata"
	valid_raw="$work_dir/valid.img"
	valid_gz="$work_dir/valid.img.gz"
	mismatch_raw="$work_dir/mismatch.img"
	extra_raw="$work_dir/extra.img"
	nonext_raw="$work_dir/non-ext4.img"
	gpt_raw="$work_dir/valid-gpt.img"
	gpt_gz="$work_dir/valid-gpt.img.gz"
	gpt_metadata="$work_dir/gpt-metadata"
	chunked_bin="$work_dir/chunked-bin"
	create_chunked_gzip_wrapper "$chunked_bin" "$(command -v gzip)"
	cat > "$metadata" <<EOF
data_partition_count=1
table_type=dos
boot_start_sector=2048
boot_sectors=8192
root_start_sector=10240
root_end_sector=75775
EOF
	write_mbr_image "$valid_raw" 65536
	gzip -c "$valid_raw" > "$valid_gz"
	write_mbr_image "$mismatch_raw" 32768
	write_mbr_image "$extra_raw" 32768 1
	cp "$valid_raw" "$nonext_raw"
	printf '\000\000' | dd of="$nonext_raw" bs=1 seek=$((10240 * 512 + 1080)) \
		conv=notrunc status=none
	cat > "$gpt_metadata" <<EOF
data_partition_count=1
table_type=gpt
boot_start_sector=512
boot_sectors=32768
root_start_sector=33280
root_end_sector=557567
EOF
	write_gpt_image "$gpt_raw" 524288
	gzip -c "$gpt_raw" > "$gpt_gz"

	OWRT_UPGRADE_GUARD_TEST_MODE=1 OWRT_UPGRADE_GUARD_TEST_METADATA="$metadata" \
		"$GUARD" "$valid_gz" 1 > "$work_dir/valid.out" 2>&1 ||
		fail "Upgrade guard rejected exact geometry"
	assert_contains "$work_dir/valid.out" "candidate geometry is compatible"
	OWRT_UPGRADE_GUARD_TEST_MODE=1 OWRT_UPGRADE_GUARD_TEST_METADATA="$gpt_metadata" \
		"$GUARD" "$gpt_raw" 1 1 > "$work_dir/valid-gpt.out" 2>&1 ||
		fail "Upgrade guard rejected exact GPT geometry"
	assert_contains "$work_dir/valid-gpt.out" "candidate geometry is compatible"
	OWRT_UPGRADE_GUARD_TEST_MODE=1 OWRT_UPGRADE_GUARD_TEST_METADATA="$gpt_metadata" \
		"$GUARD" "$gpt_gz" 1 1 > "$work_dir/valid-gpt-gzip.out" 2>&1 ||
		fail "Upgrade guard rejected exact gzip-compressed GPT geometry"
	assert_contains "$work_dir/valid-gpt-gzip.out" "candidate geometry is compatible"
	PATH="$chunked_bin:$PATH" OWRT_UPGRADE_GUARD_TEST_MODE=1 \
		OWRT_UPGRADE_GUARD_TEST_METADATA="$gpt_metadata" \
		"$GUARD" "$gpt_gz" 1 1 > "$work_dir/valid-gpt-chunked.out" 2>&1 ||
		fail "Upgrade guard rejected a valid gzip stream delivered in one-byte chunks"
	assert_contains "$work_dir/valid-gpt-chunked.out" "candidate geometry is compatible"

	for case_name in mismatch extra non-ext4 no-save no-config; do
		case "$case_name" in
			mismatch) image="$mismatch_raw"; save=1; expected="root partition geometry does not match" ;;
			extra) image="$extra_raw"; save=1; expected="unexpected partition" ;;
			non-ext4) image="$nonext_raw"; save=1; expected="is not an ext4 root filesystem" ;;
			no-save) image="$valid_raw"; save=0; expected="sysupgrade -p is blocked" ;;
			no-config) image="$valid_raw"; save=1; expected="sysupgrade -n is blocked" ;;
		esac
		keep=1
		[ "$case_name" != "no-config" ] || keep=0
		set +e
		OWRT_UPGRADE_GUARD_TEST_MODE=1 OWRT_UPGRADE_GUARD_TEST_METADATA="$metadata" \
			"$GUARD" "$image" "$save" "$keep" > "$work_dir/$case_name.out" 2>&1
		status=$?
		set -e
		[ "$status" -ne 0 ] || fail "Upgrade guard accepted $case_name"
		assert_contains "$work_dir/$case_name.out" "$expected"
	done
}

run_safe_upgrade_staging_smoke() {
	work_dir="$1/staging"
	mkdir -p "$work_dir"
	raw="$work_dir/payload.img"
	compressed="$work_dir/payload.img.gz"
	chunked_bin="$work_dir/chunked-bin"
	out_file="$work_dir/run.out"
	dd if=/dev/zero of="$raw" bs=65536 count=1 status=none
	printf 'byte-exact-safe-upgrade\n' | dd of="$raw" bs=1 seek=4093 conv=notrunc status=none
	gzip -c "$raw" > "$compressed"
	create_chunked_gzip_wrapper "$chunked_bin" "$(command -v gzip)"
	payload_size="$(wc -c < "$raw" | tr -d ' ')"
	reserve=65536
	available=$((payload_size + reserve))

	PATH="$chunked_bin:$PATH" OWRT_INSTALL_TEST_SOURCE_ONLY=1 \
		OWRT_SAFE_UPGRADE_TEST_MODE=1 OWRT_SAFE_UPGRADE_TEST_MEM_AVAILABLE="$available" \
		OWRT_SAFE_UPGRADE_RAM_RESERVE_BYTES="$reserve" TMPDIR="$work_dir" \
		UI_LIB="$UI_LIB" STORAGE_LIB="$STORAGE_LIB" sh -eu -c '
			. "$1"
			ui_install_stage() { :; }
			STORAGE_SAFE_UPGRADE=1
			PAYLOAD="$2"
			PAYLOAD_UNCOMPRESSED_SIZE="$3"
			prepare_safe_upgrade_raw_payload
			test -f "$SAFE_UPGRADE_RAW_PAYLOAD"
			test "$(stat -c %a "$SAFE_UPGRADE_RAW_PAYLOAD")" = 600
			cmp "$4" "$SAFE_UPGRADE_RAW_PAYLOAD"
			printf "staged=%s\n" "$(wc -c < "$SAFE_UPGRADE_RAW_PAYLOAD" | tr -d " ")"
			clear_safe_upgrade_raw_payload
			test -z "$SAFE_UPGRADE_RAW_PAYLOAD"
			OWRT_SAFE_UPGRADE_TEST_MEM_AVAILABLE=$((PAYLOAD_UNCOMPRESSED_SIZE + SAFE_UPGRADE_RAM_RESERVE_BYTES - 1))
			export OWRT_SAFE_UPGRADE_TEST_MEM_AVAILABLE
			if prepare_safe_upgrade_raw_payload; then exit 41; fi
			printf "low-ram=%s\n" "$SAFE_UPGRADE_STAGING_ERROR"
			test -z "$SAFE_UPGRADE_RAW_PAYLOAD"
			cleanup
		' sh "$INSTALLER" "$compressed" "$payload_size" "$raw" > "$out_file" 2>&1 || {
		sed -n '1,240p' "$out_file" >&2 || true
		fail "Safe Upgrade byte-exact staging smoke failed"
	}
	assert_contains "$out_file" "staged=$payload_size"
	assert_contains "$out_file" "low-ram=Insufficient RAM to stage the complete payload before writing"
	assert_contains "$INSTALLER" "dd if=\"\$SAFE_UPGRADE_RAW_PAYLOAD\" of=\"\$partition\""
	if sed -n '/^write_payload_partition() {/,/^}/p' "$INSTALLER" |
		grep -F "gzip -dc \"\$PAYLOAD\"" >/dev/null 2>&1; then
		fail "Safe Upgrade still slices a streaming gzip producer with dd"
	fi
	if sed -n "/if \\[ \"\$CANDIDATE_GZIP\" = \"1\" \\]; then/,/^[[:space:]]*else\$/p" \
		"$GUARD" | grep -E 'dd .*skip=.*ROOT_START' >/dev/null 2>&1; then
		fail "Upgrade guard still slices a streaming gzip producer with dd"
	fi
}

run_wrapper_smoke() {
	work_dir="$1/wrapper"
	root="$work_dir/root"
	mkdir -p "$root/sbin" "$root/etc/owrt-installer"
	# shellcheck disable=SC2016 # This writes the fake command.
	printf '%s\n' '#!/bin/sh' 'printf "real:%s\n" "$*" >> "$WRAPPER_CALLS"' > "$root/sbin/sysupgrade"
	cp "$WRAPPER" "$root/etc/owrt-installer/sysupgrade-wrapper"
	cp "$GUARD" "$root/etc/owrt-installer/upgrade-guard"
	cp "$GUARD_INSTALLER" "$root/etc/owrt-installer/install-upgrade-guard"
	chmod 0755 "$root/sbin/sysupgrade" "$root/etc/owrt-installer/"*
	"$root/etc/owrt-installer/install-upgrade-guard" "$root"
	grep -F 'OWRT_INSTALLER_SYSUPGRADE_WRAPPER=1' "$root/sbin/sysupgrade" >/dev/null ||
		fail "Guard installer did not activate wrapper"
	[ -x "$root/sbin/sysupgrade.openwrt" ] || fail "Guard installer lost original sysupgrade"
	first_sum="$(sha256sum "$root/sbin/sysupgrade.openwrt")"
	"$root/etc/owrt-installer/install-upgrade-guard" "$root"
	[ "$(sha256sum "$root/sbin/sysupgrade.openwrt")" = "$first_sum" ] ||
		fail "Repeated guard installation changed original sysupgrade"

	# Simulate a successful sysupgrade replacing /sbin while restoring /etc.
	# The early init service must adopt the new official script as its original.
	# shellcheck disable=SC2016 # This writes the fake command.
	printf '%s\n' '#!/bin/sh' 'printf "real-new:%s\n" "$*" >> "$WRAPPER_CALLS"' > "$root/sbin/sysupgrade"
	chmod 0755 "$root/sbin/sysupgrade"
	"$root/etc/owrt-installer/install-upgrade-guard" "$root"
	grep -F 'real-new:' "$root/sbin/sysupgrade.openwrt" >/dev/null ||
		fail "Guard installer did not adopt the sysupgrade script from the new image"
	grep -F 'OWRT_INSTALLER_SYSUPGRADE_WRAPPER=1' "$root/sbin/sysupgrade" >/dev/null ||
		fail "Guard installer did not restore the wrapper after sysupgrade"

	# shellcheck disable=SC2016 # This writes the fake command.
	printf '%s\n' '#!/bin/sh' 'printf "guard:%s\n" "$*" >> "$WRAPPER_CALLS"' > "$work_dir/fake-guard"
	chmod 0755 "$work_dir/fake-guard"
	: > "$work_dir/calls"
	WRAPPER_CALLS="$work_dir/calls" OWRT_INSTALLER_REAL_SYSUPGRADE="$root/sbin/sysupgrade.openwrt" \
		OWRT_INSTALLER_UPGRADE_GUARD="$work_dir/fake-guard" \
		"$root/sbin/sysupgrade" -T /tmp/candidate.img
	assert_contains "$work_dir/calls" "guard:/tmp/candidate.img 1"
	assert_contains "$work_dir/calls" "real-new:-T /tmp/candidate.img"
	: > "$work_dir/calls"
	WRAPPER_CALLS="$work_dir/calls" OWRT_INSTALLER_REAL_SYSUPGRADE="$root/sbin/sysupgrade.openwrt" \
		OWRT_INSTALLER_UPGRADE_GUARD="$work_dir/fake-guard" \
		"$root/sbin/sysupgrade" -n /tmp/candidate.img
	assert_contains "$work_dir/calls" "guard:/tmp/candidate.img 1 0"
	assert_contains "$work_dir/calls" "real-new:-n /tmp/candidate.img"
	: > "$work_dir/calls"
	WRAPPER_CALLS="$work_dir/calls" OWRT_INSTALLER_REAL_SYSUPGRADE="$root/sbin/sysupgrade.openwrt" \
		OWRT_INSTALLER_UPGRADE_GUARD="$work_dir/fake-guard" \
		"$root/sbin/sysupgrade" -b /tmp/backup.tgz
	assert_contains "$work_dir/calls" "real-new:-b /tmp/backup.tgz"
	if grep -F 'guard:' "$work_dir/calls" >/dev/null; then fail "Backup command invoked firmware guard"; fi
}

for command in sfdisk gzip fdisk sha256sum cmp stat; do
	command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

work_dir="$(mktemp -d "$TMPDIR/owrt-storage-profile-smoke.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT INT TERM
run_geometry_smoke "$work_dir"
run_target_metadata_smoke "$work_dir"
run_guard_smoke "$work_dir"
run_safe_upgrade_staging_smoke "$work_dir"
run_wrapper_smoke "$work_dir"
printf 'Storage profile and sysupgrade guard smoke tests passed.\n'
