#!/bin/sh

set -eu

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

MODE="${1:-all}"
ISO_IMAGE="${ISO_IMAGE:-$OUTPUT_DIR/openwrt-x86-64-installer-hybrid.iso}"
SMOKE_DIR="$BUILD_DIR/qemu-iso-smoke"
QEMU_TIMEOUT="${QEMU_TIMEOUT:-100s}"
QEMU_ACCEL="${QEMU_ACCEL:-tcg}"
QEMU_MEMORY="${QEMU_MEMORY:-1024}"
QEMU_SMP="${QEMU_SMP:-2}"
QEMU_VGA_WAIT="${QEMU_VGA_WAIT:-100}"
LOCAL_QEMU_ROOT="$BUILD_DIR/qemu-local/root"
QEMU_ENV_PREFIX=""
QEMU_L_ARG=""

find_first_file() {
	for file in "$@"; do
		if [ -f "$file" ]; then
			printf '%s\n' "$file"
			return 0
		fi
	done
	return 1
}

find_qemu_system() {
	if command -v qemu-system-x86_64 >/dev/null 2>&1; then
		printf '%s\n' "$(command -v qemu-system-x86_64)"
		return 0
	fi
	if [ -x "$LOCAL_QEMU_ROOT/usr/bin/qemu-system-x86_64" ]; then
		printf '%s\n' "$LOCAL_QEMU_ROOT/usr/bin/qemu-system-x86_64"
		return 0
	fi
	return 1
}

find_qemu_img() {
	if command -v qemu-img >/dev/null 2>&1; then
		printf '%s\n' "$(command -v qemu-img)"
		return 0
	fi
	if [ -x "$LOCAL_QEMU_ROOT/usr/bin/qemu-img" ]; then
		printf '%s\n' "$LOCAL_QEMU_ROOT/usr/bin/qemu-img"
		return 0
	fi
	return 1
}

configure_local_qemu_env() {
	qemu_system="$1"
	case "$qemu_system" in
		"$LOCAL_QEMU_ROOT"/*)
			qemu_lib="$LOCAL_QEMU_ROOT/usr/lib/x86_64-linux-gnu:$LOCAL_QEMU_ROOT/lib/x86_64-linux-gnu"
			qemu_modules="$LOCAL_QEMU_ROOT/usr/lib/x86_64-linux-gnu/qemu"
			qemu_data="$LOCAL_QEMU_ROOT/usr/share/qemu"
			QEMU_ENV_PREFIX="LD_LIBRARY_PATH=$qemu_lib QEMU_MODULE_DIR=$qemu_modules QEMU_AUDIO_DRV=none"
			QEMU_L_ARG="$qemu_data"
			;;
		*)
			QEMU_ENV_PREFIX="QEMU_AUDIO_DRV=none"
			QEMU_L_ARG=""
			;;
	esac
}

run_qemu_logged() {
	log_file="$1"
	shift
	status=0
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" -L "$QEMU_L_ARG" "$@" \
			> "$log_file" 2>&1 || status=$?
	else
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" "$@" \
			> "$log_file" 2>&1 || status=$?
	fi
	case "$status" in
		0|124) ;;
		*)
			tail -n 80 "$log_file" >&2 || true
			die "QEMU exited with status $status; see $log_file"
			;;
	esac
}

ensure_qcow2() {
	disk="$1"
	if [ ! -f "$disk" ]; then
		if [ -n "$QEMU_L_ARG" ]; then
			# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
			env $QEMU_ENV_PREFIX "$QEMU_IMG" create -f qcow2 "$disk" 1G >/dev/null
		else
			"$QEMU_IMG" create -f qcow2 "$disk" 1G >/dev/null
		fi
	fi
}

assert_log_contains() {
	log_file="$1"
	pattern="$2"
	if ! grep -F "$pattern" "$log_file" >/dev/null 2>&1; then
		tail -n 120 "$log_file" >&2 || true
		die "QEMU smoke log is missing marker '$pattern': $log_file"
	fi
}

assert_common_boot_markers() {
	log_file="$1"
	assert_log_contains "$log_file" "GNU GRUB"
	assert_log_contains "$log_file" "Linux version"
	assert_log_contains "$log_file" "Please press Enter to activate this console."
	assert_log_contains "$log_file" "OpenWrt disk installer is managed by /etc/inittab on tty1."
	assert_log_contains "$log_file" "OWRT_INSTALLER_UI_BACKEND=whiptail"
}

run_vga_smoke() {
	serial_log="$SMOKE_DIR/vga-iso.log"
	qemu_log="$SMOKE_DIR/vga-qemu.log"
	monitor_log="$SMOKE_DIR/vga-monitor.log"
	screenshot="$SMOKE_DIR/vga-installer.ppm"
	monitor_socket="$SMOKE_DIR/vga-monitor.sock"
	target_disk="$SMOKE_DIR/target-vga.qcow2"

	case "$QEMU_VGA_WAIT" in
		''|*[!0-9]*) die "QEMU_VGA_WAIT must be an integer number of seconds" ;;
	esac
	ensure_qcow2 "$target_disk"
	rm -f "$serial_log" "$qemu_log" "$monitor_log" "$screenshot" "$monitor_socket"

	log "Starting VGA curses UI smoke test"
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" -L "$QEMU_L_ARG" \
			-machine "q35,accel=$QEMU_ACCEL" \
			-m "$QEMU_MEMORY" \
			-smp "$QEMU_SMP" \
			-display none \
			-vga std \
			-serial "file:$serial_log" \
			-monitor "unix:$monitor_socket,server=on,wait=off" \
			-cdrom "$ISO_IMAGE" \
			-boot d \
			-drive "file=$target_disk,format=qcow2,if=virtio" \
			-nic user,model=e1000 \
			-nic user,model=e1000 > "$qemu_log" 2>&1 &
	else
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" \
			-machine "q35,accel=$QEMU_ACCEL" \
			-m "$QEMU_MEMORY" \
			-smp "$QEMU_SMP" \
			-display none \
			-vga std \
			-serial "file:$serial_log" \
			-monitor "unix:$monitor_socket,server=on,wait=off" \
			-cdrom "$ISO_IMAGE" \
			-boot d \
			-drive "file=$target_disk,format=qcow2,if=virtio" \
			-nic user,model=e1000 \
			-nic user,model=e1000 > "$qemu_log" 2>&1 &
	fi
	qemu_pid=$!

	elapsed=0
	while [ "$elapsed" -lt "$QEMU_VGA_WAIT" ]; do
		if [ -S "$monitor_socket" ] && [ -r "$serial_log" ] &&
			grep -F "OWRT_INSTALLER_UI_READY=target-disk" "$serial_log" >/dev/null 2>&1; then
			break
		fi
		if ! kill -0 "$qemu_pid" 2>/dev/null; then
			wait "$qemu_pid" || true
			tail -n 80 "$qemu_log" >&2 || true
			die "QEMU exited before the VGA installer became ready"
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	if [ "$elapsed" -ge "$QEMU_VGA_WAIT" ]; then
		printf 'quit\n' | nc -U "$monitor_socket" >/dev/null 2>&1 || true
		wait "$qemu_pid" || true
		tail -n 120 "$serial_log" >&2 || true
		die "VGA installer did not reach the target-disk menu within ${QEMU_VGA_WAIT}s"
	fi

	sleep 2
	printf 'screendump %s\ninfo status\nquit\n' "$screenshot" |
		nc -U "$monitor_socket" > "$monitor_log" 2>&1 || true
	wait "$qemu_pid" || true

	[ -s "$screenshot" ] || die "QEMU VGA screenshot was not created: $screenshot"
	[ "$(dd if="$screenshot" bs=1 count=2 2>/dev/null)" = "P6" ] ||
		die "QEMU VGA screenshot is not a binary PPM image"
	pixel_values="$(dd if="$screenshot" bs=1 skip=64 2>/dev/null | od -An -tu1 | tr ' ' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
	[ "$pixel_values" -ge 4 ] || die "QEMU VGA screenshot appears blank"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_UI_BACKEND=whiptail"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk"
	log "VGA curses UI smoke passed: $screenshot"
}

run_bios_smoke() {
	log_file="$SMOKE_DIR/bios-iso.log"
	target_disk="$SMOKE_DIR/target-bios.qcow2"

	ensure_qcow2 "$target_disk"
	log "Starting BIOS hybrid ISO smoke test"
	run_qemu_logged "$log_file" \
		-machine "q35,accel=$QEMU_ACCEL" \
		-m "$QEMU_MEMORY" \
		-smp "$QEMU_SMP" \
		-nographic \
		-cdrom "$ISO_IMAGE" \
		-boot d \
		-drive "file=$target_disk,format=qcow2,if=virtio" \
		-nic user,model=e1000 \
		-nic user,model=e1000

	assert_log_contains "$log_file" "Booting from DVD/CD"
	assert_common_boot_markers "$log_file"
	log "BIOS hybrid ISO smoke passed: $log_file"
}

run_uefi_smoke() {
	log_file="$SMOKE_DIR/uefi-iso.log"
	target_disk="$SMOKE_DIR/target-uefi.qcow2"
	vars_copy="$SMOKE_DIR/OVMF_VARS_4M-iso.fd"

	ovmf_code="${OVMF_CODE:-$(find_first_file \
		"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_CODE_4M.fd" \
		"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_CODE.fd" \
		/usr/share/OVMF/OVMF_CODE_4M.fd \
		/usr/share/OVMF/OVMF_CODE.fd \
		/usr/share/edk2/x64/OVMF_CODE.fd \
		/usr/share/qemu/OVMF_CODE.fd || true)}"
	ovmf_vars="${OVMF_VARS:-$(find_first_file \
		"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_VARS_4M.fd" \
		"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_VARS.fd" \
		/usr/share/OVMF/OVMF_VARS_4M.fd \
		/usr/share/OVMF/OVMF_VARS.fd \
		/usr/share/edk2/x64/OVMF_VARS.fd \
		/usr/share/qemu/OVMF_VARS.fd || true)}"

	[ -f "$ovmf_code" ] || die "OVMF_CODE.fd not found; set OVMF_CODE explicitly"
	[ -f "$ovmf_vars" ] || die "OVMF_VARS.fd not found; set OVMF_VARS explicitly"

	ensure_qcow2 "$target_disk"
	cp "$ovmf_vars" "$vars_copy"

	log "Starting UEFI hybrid ISO smoke test"
	run_qemu_logged "$log_file" \
		-machine "q35,accel=$QEMU_ACCEL" \
		-m "$QEMU_MEMORY" \
		-smp "$QEMU_SMP" \
		-nographic \
		-drive "if=pflash,format=raw,readonly=on,file=$ovmf_code" \
		-drive "if=pflash,format=raw,file=$vars_copy" \
		-cdrom "$ISO_IMAGE" \
		-boot d \
		-drive "file=$target_disk,format=qcow2,if=virtio" \
		-nic user,model=e1000 \
		-nic user,model=e1000

	assert_log_contains "$log_file" "BdsDxe: starting"
	assert_log_contains "$log_file" "EFI stub"
	assert_common_boot_markers "$log_file"
	log "UEFI hybrid ISO smoke passed: $log_file"
}

case "$MODE" in
	all|bios|uefi|vga) ;;
	*) die "Usage: $0 [all|bios|uefi|vga]" ;;
esac

[ -s "$ISO_IMAGE" ] || die "Hybrid ISO is missing. Run: make iso"
require_cmd timeout
require_cmd grep
require_cmd tail
case "$MODE" in
	all|vga)
		require_cmd nc
		require_cmd od
		;;
esac
mkdir -p "$SMOKE_DIR"

QEMU_SYSTEM="$(find_qemu_system)" || die "qemu-system-x86_64 is required"
QEMU_IMG="$(find_qemu_img)" || die "qemu-img is required"
configure_local_qemu_env "$QEMU_SYSTEM"

case "$MODE" in
	all)
		run_bios_smoke
		run_uefi_smoke
		run_vga_smoke
		;;
	bios)
		run_bios_smoke
		;;
	uefi)
		run_uefi_smoke
		;;
	vga)
		run_vga_smoke
		;;
esac

log "QEMU hybrid ISO smoke tests passed"
