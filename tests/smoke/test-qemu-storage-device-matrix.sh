#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
ROOT_PROJECT_DIR="$PROJECT_DIR"
BUILD_DIR="$PROJECT_DIR/build"
OUTPUT_DIR="$PROJECT_DIR/output"
export BUILD_DIR OUTPUT_DIR
TMP_ROOT="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "$TMP_ROOT/owrt-qemu-device-matrix.XXXXXX")"
HARNESS_LIB="$WORK_DIR/qemu-harness-lib.sh"
ACTIVE_PID=""
ACTIVE_MONITOR=""
TEST_MODE="${1:-all}"

case "$TEST_MODE" in
	all|devices|pre-erase) ;;
	*) printf 'Usage: %s [all|devices|pre-erase]\n' "$0" >&2; exit 2 ;;
esac

cleanup_device_matrix() {
	if [ -n "$ACTIVE_MONITOR" ] && [ -S "$ACTIVE_MONITOR" ]; then
		hmp_command "$ACTIVE_MONITOR" quit >/dev/null 2>&1 || true
		sleep 1
	fi
	if [ -n "$ACTIVE_PID" ]; then
		kill "$ACTIVE_PID" >/dev/null 2>&1 || true
		wait "$ACTIVE_PID" >/dev/null 2>&1 || true
	fi
	rm -rf "$WORK_DIR"
}

trap cleanup_device_matrix EXIT INT TERM HUP

# Reuse the release-tested QEMU helpers without executing that script's mode
# dispatcher. The generated copy points at the real shared common library.
awk -v common="$PROJECT_DIR/scripts/common.sh" '
	$0 == ". \"$(dirname \"$0\")/common.sh\"" {
		print ". \"" common "\""
		next
	}
	/^case "\$MODE" in$/ { exit }
	{ print }
' "$PROJECT_DIR/scripts/test-qemu-iso-smoke.sh" > "$HARNESS_LIB"

# shellcheck source=/dev/null
. "$HARNESS_LIB"
PROJECT_DIR="$ROOT_PROJECT_DIR"

SMOKE_DIR="$BUILD_DIR/qemu-storage-device-matrix"
QEMU_INSTALL_WAIT="${QEMU_INSTALL_WAIT:-360}"
QEMU_INSTALL_TIMEOUT="${QEMU_INSTALL_TIMEOUT:-480s}"
QEMU_SMP="${QEMU_SMP:-2}"
mkdir -p "$SMOKE_DIR"

require_cmd nc
require_cmd fdisk
require_cmd sfdisk
[ -s "$ISO_IMAGE" ] || die "Frozen hybrid ISO is missing: $ISO_IMAGE"
[ -s "$TARGET_IMAGE" ] || die "Embedded target image is missing: $TARGET_IMAGE"
[ -s "$ISO_STAGED_KERNEL" ] || die "Staged installer kernel is missing"
[ -s "$ISO_STAGED_INITRAMFS" ] || die "Staged installer initramfs is missing"
[ -x "$IMAGEBUILDER_DIR/staging_dir/host/bin/mcopy" ] ||
	die "ImageBuilder mcopy is required for the pre-ERASE rescue fixture"

QEMU_SYSTEM="$(find_qemu_system)" || die "qemu-system-x86_64 is required"
QEMU_IMG="$(find_qemu_img)" || die "qemu-img is required"
configure_local_qemu_env "$QEMU_SYSTEM"
find_ovmf

qemu_img_compare() {
	reference_disk="$1"
	actual_disk="$2"
	message="$3"
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		env $QEMU_ENV_PREFIX "$QEMU_IMG" compare -f qcow2 -F qcow2 \
			"$reference_disk" "$actual_disk" >/dev/null || die "$message"
	else
		"$QEMU_IMG" compare -f qcow2 -F qcow2 \
			"$reference_disk" "$actual_disk" >/dev/null || die "$message"
	fi
}

send_exact_erase() {
	monitor_socket="$1"
	target_name="$2"
	case "$target_name" in
		sda)
			hmp_send_keys "$monitor_socket" shift-e shift-r shift-a shift-s shift-e \
				spc slash d e v slash s d a ret
			;;
		nvme0n1)
			hmp_send_keys "$monitor_socket" shift-e shift-r shift-a shift-s shift-e \
				spc slash d e v slash n v m e 0 n 1 ret
			;;
		*) die "Unsupported exact-erase target name: $target_name" ;;
	esac
}

start_device_qemu() {
	device_kind="$1"
	qemu_timeout="$2"
	qemu_log="$3"
	target_disk="$4"
	guard_disk="$5"
	vars_copy="$6"
	serial_arg="$7"
	monitor_socket="$8"
	boot_mode="$9"

	# shellcheck disable=SC2086 # Controlled QEMU serial option and value pairs.
	set -- \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none -vga std $serial_arg \
		-monitor "unix:$monitor_socket,server=on,wait=off" \
		-drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$vars_copy"
	if [ "$boot_mode" = "installer" ]; then
		set -- "$@" -cdrom "$ISO_IMAGE" -boot d
	else
		set -- "$@" -boot c
	fi
	case "$device_kind" in
		sata)
		set -- "$@" \
			-device ich9-ahci,id=owrtahci \
			-drive "if=none,id=target,file=$target_disk,format=qcow2" \
			-device ide-hd,drive=target,bus=owrtahci.0 \
			-drive "file=$guard_disk,format=qcow2,if=virtio"
		;;
		nvme)
		set -- "$@" \
			-drive "if=none,id=target,file=$target_disk,format=qcow2" \
			-device nvme,drive=target,serial=OWRTNVME0001 \
			-drive "file=$guard_disk,format=qcow2,if=virtio"
		;;
		*) die "Unsupported QEMU storage device kind: $device_kind" ;;
	esac
	set -- "$@" -nic user,model=e1000 -nic user,model=e1000
	start_qemu_background "$qemu_timeout" "$qemu_log" "$@"
	ACTIVE_PID="$QEMU_STARTED_PID"
	ACTIVE_MONITOR="$monitor_socket"
}

drive_candidate_install() {
	serial_log="$1"
	monitor_socket="$2"
	install_pid="$3"
	target_name="$4"
	wait_limit="$5"

	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=install-type" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-profile" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=lan-interface" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=wan-interface-auto" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=lan-ip" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=wan-mode" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=wan6-mode" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=review-summary" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=review-action" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=final-erase-info" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=exact-erase" "$install_pid" "$wait_limit"
	send_exact_erase "$monitor_socket" "$target_name"
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS=100" "$install_pid" "$wait_limit"
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_ROOTFS_VERIFIED_MIB=" "$install_pid" "$wait_limit"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=installation-success" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=post-install-menu" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" down down ret
	sleep 2
	hmp_command "$monitor_socket" quit
	wait "$install_pid" || true
	ACTIVE_PID=""
	ACTIVE_MONITOR=""
}

verify_device_boot() {
	device_kind="$1"
	target_name="$2"
	root_name="$3"
	data_name="$4"
	target_disk="$5"
	guard_disk="$6"
	vars_copy="$7"
	prefix="$8"
	serial_log="$SMOKE_DIR/$prefix-installed.log"
	qemu_log="$SMOKE_DIR/$prefix-installed-qemu.log"
	serial_socket="$SMOKE_DIR/$prefix-installed-serial.sock"
	monitor_socket="$SMOKE_DIR/$prefix-installed-monitor.sock"
	rm -f "$serial_log" "$qemu_log" "$serial_socket" "$monitor_socket"

	start_device_qemu "$device_kind" "$QEMU_INSTALL_TIMEOUT" "$qemu_log" \
		"$target_disk" "$guard_disk" "$vars_copy" \
		"-chardev socket,id=serial0,path=$serial_socket,server=on,wait=off,logfile=$serial_log -serial chardev:serial0" \
		"$monitor_socket" installed
	boot_pid="$ACTIVE_PID"
	wait_for_log_marker "$serial_log" "Please press Enter to activate this console." "$boot_pid" "$QEMU_INSTALL_WAIT"
	{
		printf '\r'
		sleep 1
		# shellcheck disable=SC2016 # Evaluated by the guest shell.
		printf '%s\r' 'wait_i=0; while ! grep " /mnt/data ext4 " /proc/mounts >/dev/null; do sleep 1; wait_i=$((wait_i + 1)); [ "$wait_i" -lt 120 ] || break; done'
		sleep 1
		printf 'target_name=%s; root_name=%s; data_name=%s\r' \
			"$target_name" "$root_name" "$data_name"
		sleep 1
		# shellcheck disable=SC2016 # Evaluated by the guest shell.
		printf '%s\r' 'root_start=$(cat "/sys/class/block/$root_name/start"); root_sectors=$(cat "/sys/class/block/$root_name/size"); data_start=$(cat "/sys/class/block/$data_name/start"); data_sectors=$(cat "/sys/class/block/$data_name/size"); disk_sectors=$(cat "/sys/class/block/$target_name/size")'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'meta_target=$(sed -n '\''s/^target_disk=//p'\'' /etc/openwrt-installer-release); meta_layout=$(sed -n '\''s/^storage_layout=//p'\'' /etc/openwrt-installer-release); meta_profile=$(uci -q get owrt-installer.layout.profile); meta_table=$(uci -q get owrt-installer.layout.table_type)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'meta_root_start=$(uci -q get owrt-installer.layout.root_start_sector); meta_root_end=$(uci -q get owrt-installer.layout.root_end_sector); meta_data_count=$(uci -q get owrt-installer.layout.data_partition_count); meta_reserve=$(uci -q get owrt-installer.layout.reserve_sectors)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'root_uuid=$(blkid -s PARTUUID -o value "/dev/$root_name"); data_uuid=$(blkid -s UUID -o value "/dev/$data_name"); meta_data_uuid=$(uci -q get owrt-installer.partition3.uuid); fstab_uuid=$(uci -q get fstab.owrt_data_3.uuid)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'partuuid_ok=0; grep -q "root=PARTUUID=$root_uuid" /proc/cmdline && partuuid_ok=1; root_mount_ok=0; grep " / ext4 " /proc/mounts >/dev/null && root_mount_ok=1; data_mount_ok=0; grep " /mnt/data ext4 " /proc/mounts >/dev/null && data_mount_ok=1'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'usable_end=$((disk_sectors - 34)); remaining=$((usable_end - data_start + 1)); expected_data=$((((remaining * 80 / 100) / 2048) * 2048)); actual_reserve=$((usable_end - data_start - data_sectors + 1))'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'geometry_ok=1; [ "$root_start" = "$meta_root_start" ] && [ "$((root_start + root_sectors - 1))" = "$meta_root_end" ] || geometry_ok=0; [ "$data_sectors" = "$expected_data" ] && [ "$actual_reserve" = "$meta_reserve" ] || geometry_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'metadata_ok=1; [ "$meta_profile" = compatible ] && [ "$meta_layout" = image ] && [ "$meta_table" = gpt ] || metadata_ok=0; [ "$meta_data_count" = 1 ] && [ "$meta_reserve" -gt 0 ] || metadata_ok=0; [ "$data_uuid" = "$meta_data_uuid" ] && [ "$data_uuid" = "$fstab_uuid" ] || metadata_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'guard=0; grep -q OWRT_INSTALLER_SYSUPGRADE_WRAPPER=1 /sbin/sysupgrade && guard=1; data_type=$(blkid -s TYPE -o value "/dev/$data_name")'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'printf "OWRT_DEVICE_BOOT target=%s root=%s data=%s profile=%s layout=%s geometry=%s metadata=%s partuuid=%s root_mount=%s data_mount=%s guard=%s reserve=%s\n" "$meta_target" "$root_name" "$data_name" "$meta_profile" "$meta_layout" "$geometry_ok" "$metadata_ok" "$partuuid_ok" "$root_mount_ok" "$data_mount_ok" "$guard" "$meta_reserve"'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'if [ "$meta_target" = "/dev/$target_name" ] && [ "$data_type" = ext4 ] && [ "$geometry_ok" = 1 ] && [ "$metadata_ok" = 1 ] && [ "$partuuid_ok" = 1 ] && [ "$root_mount_ok" = 1 ] && [ "$data_mount_ok" = 1 ] && [ "$guard" = 1 ]; then echo OWRT_DEVICE_BOOT_""OK=1; fi'
	} | nc -N -U "$serial_socket" >/dev/null 2>&1 || die "Could not query installed $target_name system"
	wait_for_log_marker "$serial_log" "OWRT_DEVICE_BOOT_OK=1" "$boot_pid" "$QEMU_INSTALL_WAIT"
	hmp_command "$monitor_socket" quit
	wait "$boot_pid" || true
	ACTIVE_PID=""
	ACTIVE_MONITOR=""
	assert_log_contains "$serial_log" "OWRT_DEVICE_BOOT target=/dev/$target_name"
}

run_device_install() {
	device_kind="$1"
	target_name="$2"
	root_name="$3"
	data_name="$4"
	prefix="$5"
	target_disk="$SMOKE_DIR/$prefix-target.qcow2"
	guard_disk="$SMOKE_DIR/$prefix-guard.qcow2"
	guard_reference="$SMOKE_DIR/$prefix-guard-reference.qcow2"
	vars_copy="$SMOKE_DIR/$prefix-OVMF_VARS.fd"
	serial_log="$SMOKE_DIR/$prefix-installer.log"
	qemu_log="$SMOKE_DIR/$prefix-installer-qemu.log"
	monitor_socket="$SMOKE_DIR/$prefix-installer-monitor.sock"
	rm -f "$target_disk" "$guard_disk" "$guard_reference" "$vars_copy" \
		"$serial_log" "$qemu_log" "$monitor_socket"
	create_qcow2 "$target_disk" 6G
	create_qcow2 "$guard_disk" 64M
	cp "$guard_disk" "$guard_reference"
	cp "$QEMU_OVMF_VARS" "$vars_copy"

	log "Starting frozen-ISO install on /dev/$target_name with unrelated guard disk"
	start_device_qemu "$device_kind" "$QEMU_INSTALL_TIMEOUT" "$qemu_log" \
		"$target_disk" "$guard_disk" "$vars_copy" "-serial file:$serial_log" \
		"$monitor_socket" installer
	install_pid="$ACTIVE_PID"
	drive_candidate_install "$serial_log" "$monitor_socket" "$install_pid" \
		"$target_name" "$QEMU_INSTALL_WAIT"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_STORAGE_LAYOUT=image"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_STORAGE_PROFILE=compatible"
	assert_log_not_contains "$serial_log" "Installation failed"
	verify_host_gpt_tail "$target_disk" "$prefix"
	qemu_img_compare "$guard_reference" "$guard_disk" \
		"Installer modified unrelated guard disk during $target_name installation"
	verify_device_boot "$device_kind" "$target_name" "$root_name" "$data_name" "$target_disk" \
		"$guard_disk" "$vars_copy" "$prefix"
	qemu_img_compare "$guard_reference" "$guard_disk" \
		"Installed-system boot modified unrelated guard disk in $target_name test"
	log "Frozen-ISO /dev/$target_name install, boot, and guard-disk check passed"
}

run_pre_erase_rescue_immutability() {
	target_disk="$(prepare_local_boot_disk pre-erase-rescue)"
	resize_qcow2 "$target_disk" 6G
	target_reference="$SMOKE_DIR/pre-erase-rescue-reference.qcow2"
	vars_copy="$SMOKE_DIR/pre-erase-rescue-OVMF_VARS.fd"
	serial_log="$SMOKE_DIR/pre-erase-rescue-installer.log"
	qemu_log="$SMOKE_DIR/pre-erase-rescue-installer-qemu.log"
	monitor_socket="$SMOKE_DIR/pre-erase-rescue-monitor.sock"
	rm -f "$target_reference" "$vars_copy" "$serial_log" "$qemu_log" "$monitor_socket"
	cp "$target_disk" "$target_reference"
	cp "$QEMU_OVMF_VARS" "$vars_copy"

	log "Starting rescue snapshot and pre-ERASE power-off immutability check"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$qemu_log" \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none -vga std -serial "file:$serial_log" \
		-monitor "unix:$monitor_socket,server=on,wait=off" \
		-kernel "$ISO_STAGED_KERNEL" -initrd "$ISO_STAGED_INITRAMFS" \
		-append "console=tty1 console=ttyS0,115200n8 rdinit=/init owrt.mouse=1" \
		-drive "file=$target_disk,format=qcow2,if=virtio" \
		-nic user,model=e1000 -nic user,model=e1000
	ACTIVE_PID="$QEMU_STARTED_PID"
	ACTIVE_MONITOR="$monitor_socket"
	install_pid="$ACTIVE_PID"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=existing-system-action" "$install_pid" "$QEMU_INSTALL_WAIT"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_EXISTING_RESCUE=ready"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=rescue-scope" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_either_log_marker "$serial_log" \
		"OWRT_INSTALLER_UI_READY=config-import-network" \
		"OWRT_INSTALLER_UI_READY=rescue-ready" "$install_pid" "$QEMU_INSTALL_WAIT"
	sleep "$QEMU_UI_SETTLE"
	if [ "$WAITED_LOG_MARKER" = "OWRT_INSTALLER_UI_READY=config-import-network" ]; then
		hmp_send_keys "$monitor_socket" ret
		wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=rescue-ready" "$install_pid" "$QEMU_INSTALL_WAIT"
	fi
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-profile" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" down ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-layout" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-warning" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_either_log_marker "$serial_log" \
		"OWRT_INSTALLER_UI_READY=review-summary" \
		"OWRT_INSTALLER_UI_READY=lan-interface" "$install_pid" "$QEMU_INSTALL_WAIT"
	sleep "$QEMU_UI_SETTLE"
	if [ "$WAITED_LOG_MARKER" = "OWRT_INSTALLER_UI_READY=lan-interface" ]; then
		hmp_send_keys "$monitor_socket" ret
		wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=wan-interface-auto" "$install_pid" "$QEMU_INSTALL_WAIT"
		hmp_send_keys "$monitor_socket" ret
		wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=lan-ip" "$install_pid" "$QEMU_INSTALL_WAIT"
		hmp_send_keys "$monitor_socket" ret
		wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=wan-mode" "$install_pid" "$QEMU_INSTALL_WAIT"
		hmp_send_keys "$monitor_socket" ret
		wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=wan6-mode" "$install_pid" "$QEMU_INSTALL_WAIT"
		hmp_send_keys "$monitor_socket" ret
		wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=review-summary" "$install_pid" "$QEMU_INSTALL_WAIT"
	fi
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=review-action" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=final-erase-info" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=exact-erase" "$install_pid" "$QEMU_INSTALL_WAIT"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_RESCUE_READY=$OPENWRT_VERSION:config-only"
	assert_log_not_contains "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS="
	hmp_command "$monitor_socket" quit
	wait "$install_pid" || true
	ACTIVE_PID=""
	ACTIVE_MONITOR=""
	qemu_img_compare "$target_reference" "$target_disk" \
		"Rescue snapshot or pre-ERASE review modified the source disk"
	log "Rescue snapshot and pre-ERASE power-off disk immutability passed"
}

case "$TEST_MODE" in
all|devices)
	run_device_install sata sda sda2 sda3 sata
	run_device_install nvme nvme0n1 nvme0n1p2 nvme0n1p3 nvme
	;;
esac
case "$TEST_MODE" in
	all|pre-erase) run_pre_erase_rescue_immutability ;;
esac

log "Frozen-candidate storage device matrix mode '$TEST_MODE' passed"
