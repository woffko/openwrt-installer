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
QEMU_INSTALL_WAIT="${QEMU_INSTALL_WAIT:-300}"
QEMU_INSTALL_TIMEOUT="${QEMU_INSTALL_TIMEOUT:-360s}"
QEMU_UI_SETTLE="${QEMU_UI_SETTLE:-1}"
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

assert_log_not_contains() {
	log_file="$1"
	pattern="$2"
	if grep -F "$pattern" "$log_file" >/dev/null 2>&1; then
		tail -n 120 "$log_file" >&2 || true
		die "QEMU smoke log unexpectedly contains '$pattern': $log_file"
	fi
}

wait_for_log_marker() {
	log_file="$1"
	pattern="$2"
	qemu_pid="$3"
	max_wait="$4"
	wait_elapsed=0
	while [ "$wait_elapsed" -lt "$max_wait" ]; do
		if [ -r "$log_file" ] && grep -F "$pattern" "$log_file" >/dev/null 2>&1; then
			return 0
		fi
		if ! kill -0 "$qemu_pid" 2>/dev/null; then
			wait "$qemu_pid" || true
			tail -n 120 "$log_file" >&2 2>/dev/null || true
			die "QEMU exited before marker '$pattern'"
		fi
		sleep 1
		wait_elapsed=$((wait_elapsed + 1))
	done
	tail -n 120 "$log_file" >&2 2>/dev/null || true
	die "Timed out waiting for marker '$pattern' after ${max_wait}s"
}

wait_for_ui_marker() {
	log_file="$1"
	pattern="$2"
	qemu_pid="$3"
	max_wait="$4"
	wait_for_log_marker "$log_file" "$pattern" "$qemu_pid" "$max_wait"
	# The serial marker is emitted immediately before whiptail takes over the TTY.
	sleep "$QEMU_UI_SETTLE"
}

hmp_send_keys() {
	monitor_socket="$1"
	shift
	{
		for hmp_key in "$@"; do
			printf 'sendkey %s\n' "$hmp_key"
			sleep 0.15
		done
	} | nc -N -U "$monitor_socket" >/dev/null 2>&1 ||
		die "Could not send keys through QEMU monitor"
}

hmp_command() {
	monitor_socket="$1"
	shift
	printf '%s\n' "$*" | nc -N -U "$monitor_socket" >/dev/null 2>&1 ||
		die "Could not send QEMU monitor command: $*"
}

assert_nonblank_ppm() {
	screenshot="$1"
	[ -s "$screenshot" ] || die "QEMU VGA screenshot was not created: $screenshot"
	[ "$(dd if="$screenshot" bs=1 count=2 2>/dev/null)" = "P6" ] ||
		die "QEMU VGA screenshot is not a binary PPM image"
	pixel_values="$(dd if="$screenshot" bs=1 skip=64 2>/dev/null | od -An -tu1 | tr ' ' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
	[ "$pixel_values" -ge 4 ] || die "QEMU VGA screenshot appears blank"
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

	assert_nonblank_ppm "$screenshot"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_UI_BACKEND=whiptail"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk"
	log "VGA curses UI smoke passed: $screenshot"
}

run_install_smoke() {
	serial_log="$SMOKE_DIR/install-iso.log"
	qemu_log="$SMOKE_DIR/install-qemu.log"
	monitor_socket="$SMOKE_DIR/install-monitor.sock"
	progress_screenshot="$SMOKE_DIR/install-progress.ppm"
	target_disk="$SMOKE_DIR/target-install.qcow2"
	boot_serial_log="$SMOKE_DIR/installed-boot.log"
	boot_qemu_log="$SMOKE_DIR/installed-boot-qemu.log"
	boot_serial_socket="$SMOKE_DIR/installed-serial.sock"
	boot_monitor_socket="$SMOKE_DIR/installed-monitor.sock"

	case "$QEMU_INSTALL_WAIT" in
		''|*[!0-9]*) die "QEMU_INSTALL_WAIT must be an integer number of seconds" ;;
	esac
	rm -f "$target_disk" "$serial_log" "$qemu_log" "$monitor_socket" \
		"$progress_screenshot" "$boot_serial_log" "$boot_qemu_log" \
		"$boot_serial_socket" "$boot_monitor_socket"
	ensure_qcow2 "$target_disk"

	log "Starting automated VGA installation smoke test"
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_INSTALL_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" -L "$QEMU_L_ARG" \
			-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
			-display none -vga std -serial "file:$serial_log" \
			-monitor "unix:$monitor_socket,server=on,wait=off" \
			-cdrom "$ISO_IMAGE" -boot d \
			-drive "file=$target_disk,format=qcow2,if=virtio" \
			-nic user,model=e1000 -nic user,model=e1000 > "$qemu_log" 2>&1 &
	else
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_INSTALL_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" \
			-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
			-display none -vga std -serial "file:$serial_log" \
			-monitor "unix:$monitor_socket,server=on,wait=off" \
			-cdrom "$ISO_IMAGE" -boot d \
			-drive "file=$target_disk,format=qcow2,if=virtio" \
			-nic user,model=e1000 -nic user,model=e1000 > "$qemu_log" 2>&1 &
	fi
	install_pid=$!

	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=lan-interface" "$install_pid" "$QEMU_INSTALL_WAIT"
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
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=review-action" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=final-erase-info" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=exact-erase" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" shift-e shift-r shift-a shift-s shift-e spc slash d e v slash v d a ret

	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS=" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_command "$monitor_socket" "screendump $progress_screenshot"
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS=100" "$install_pid" "$QEMU_INSTALL_WAIT"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=installation-success" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=post-install-menu" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" down down ret
	sleep 2
	hmp_command "$monitor_socket" quit
	wait "$install_pid" || true

	assert_nonblank_ppm "$progress_screenshot"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_UI_BACKEND=whiptail"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS=100"
	assert_log_not_contains "$serial_log" "Installation failed"

	log "Booting the disk written by the installer"
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_INSTALL_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" -L "$QEMU_L_ARG" \
			-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
			-display none \
			-chardev "socket,id=serial0,path=$boot_serial_socket,server=on,wait=off,logfile=$boot_serial_log" \
			-serial chardev:serial0 -monitor "unix:$boot_monitor_socket,server=on,wait=off" \
			-drive "file=$target_disk,format=qcow2,if=virtio" -boot c \
			-nic user,model=e1000 -nic user,model=e1000 > "$boot_qemu_log" 2>&1 &
	else
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_INSTALL_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" \
			-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
			-display none \
			-chardev "socket,id=serial0,path=$boot_serial_socket,server=on,wait=off,logfile=$boot_serial_log" \
			-serial chardev:serial0 -monitor "unix:$boot_monitor_socket,server=on,wait=off" \
			-drive "file=$target_disk,format=qcow2,if=virtio" -boot c \
			-nic user,model=e1000 -nic user,model=e1000 > "$boot_qemu_log" 2>&1 &
	fi
	boot_pid=$!
	wait_for_log_marker "$boot_serial_log" "Please press Enter to activate this console." "$boot_pid" "$QEMU_INSTALL_WAIT"
	{ printf '\r'; sleep 1; printf 'cat /etc/openwrt-installer-release\r'; } |
		nc -N -U "$boot_serial_socket" >/dev/null 2>&1 || die "Could not query installed system console"
	wait_for_log_marker "$boot_serial_log" "installer_version=$INSTALLER_VERSION" "$boot_pid" "$QEMU_INSTALL_WAIT"
	hmp_command "$boot_monitor_socket" quit
	wait "$boot_pid" || true
	assert_log_contains "$boot_serial_log" "installed_by=openwrt-x86-installer"
	assert_log_contains "$boot_serial_log" "target_disk=/dev/vda"
	log "Automated install and installed-system boot smoke passed"
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
	all|bios|uefi|vga|install) ;;
	*) die "Usage: $0 [all|bios|uefi|vga|install]" ;;
esac

[ -s "$ISO_IMAGE" ] || die "Hybrid ISO is missing. Run: make iso"
require_cmd timeout
require_cmd grep
require_cmd tail
case "$MODE" in
	all|vga|install)
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
		run_install_smoke
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
	install)
		run_install_smoke
		;;
esac

log "QEMU hybrid ISO smoke tests passed"
