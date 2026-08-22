#!/bin/sh

set -eu

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

MODE="${1:-all}"
ISO_IMAGE="${ISO_IMAGE:-$OUTPUT_DIR/openwrt-x86-64-installer-hybrid.iso}"
TARGET_IMAGE="${TARGET_IMAGE:-$OUTPUT_DIR/openwrt-x86-64-target.img.gz}"
ISO_STAGED_KERNEL="${ISO_STAGED_KERNEL:-$BUILD_DIR/hybrid-iso/root/boot/vmlinuz}"
ISO_STAGED_INITRAMFS="${ISO_STAGED_INITRAMFS:-$BUILD_DIR/hybrid-iso/root/boot/initramfs.cpio.gz}"
SMOKE_DIR="$BUILD_DIR/qemu-iso-smoke"
QEMU_TIMEOUT="${QEMU_TIMEOUT:-100s}"
QEMU_ACCEL="${QEMU_ACCEL:-tcg}"
QEMU_MEMORY="${QEMU_MEMORY:-1024}"
QEMU_SMP="${QEMU_SMP:-2}"
QEMU_VGA_WAIT="${QEMU_VGA_WAIT:-100}"
QEMU_HARDWARE_WAIT="${QEMU_HARDWARE_WAIT:-100}"
QEMU_INSTALL_WAIT="${QEMU_INSTALL_WAIT:-300}"
QEMU_INSTALL_TIMEOUT="${QEMU_INSTALL_TIMEOUT:-360s}"
QEMU_ONLINE_WAIT="${QEMU_ONLINE_WAIT:-420}"
QEMU_ONLINE_TIMEOUT="${QEMU_ONLINE_TIMEOUT:-600s}"
QEMU_STANDARD_UPGRADE_WAIT="${QEMU_STANDARD_UPGRADE_WAIT:-600}"
QEMU_STANDARD_UPGRADE_TIMEOUT="${QEMU_STANDARD_UPGRADE_TIMEOUT:-1200s}"
# QEMU 8.2 TCG can stall the guest clock after a warm reset with SMP enabled.
# Keep this gate on one vCPU so it still validates the real reboot path.
QEMU_STANDARD_UPGRADE_SMP="${QEMU_STANDARD_UPGRADE_SMP:-1}"
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

create_qcow2() {
	disk="$1"
	size="$2"
	rm -f "$disk"
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		env $QEMU_ENV_PREFIX "$QEMU_IMG" create -f qcow2 "$disk" "$size" >/dev/null
	else
		"$QEMU_IMG" create -f qcow2 "$disk" "$size" >/dev/null
	fi
}

resize_qcow2() {
	disk="$1"
	size="$2"
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		env $QEMU_ENV_PREFIX "$QEMU_IMG" resize "$disk" "$size" >/dev/null
	else
		"$QEMU_IMG" resize "$disk" "$size" >/dev/null
	fi
}

start_qemu_background() {
	qemu_timeout="$1"
	qemu_log="$2"
	shift 2
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$qemu_timeout" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" -L "$QEMU_L_ARG" "$@" \
			> "$qemu_log" 2>&1 &
	else
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$qemu_timeout" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" "$@" \
			> "$qemu_log" 2>&1 &
	fi
	QEMU_STARTED_PID=$!
}

find_ovmf() {
	QEMU_OVMF_CODE="${OVMF_CODE:-$(find_first_file \
		"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_CODE_4M.fd" \
		"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_CODE.fd" \
		/usr/share/OVMF/OVMF_CODE_4M.fd \
		/usr/share/OVMF/OVMF_CODE.fd \
		/usr/share/edk2/x64/OVMF_CODE.fd \
		/usr/share/qemu/OVMF_CODE.fd || true)}"
	QEMU_OVMF_VARS="${OVMF_VARS:-$(find_first_file \
		"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_VARS_4M.fd" \
		"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_VARS.fd" \
		/usr/share/OVMF/OVMF_VARS_4M.fd \
		/usr/share/OVMF/OVMF_VARS.fd \
		/usr/share/edk2/x64/OVMF_VARS.fd \
		/usr/share/qemu/OVMF_VARS.fd || true)}"
	[ -f "$QEMU_OVMF_CODE" ] || die "OVMF_CODE.fd not found"
	[ -f "$QEMU_OVMF_VARS" ] || die "OVMF_VARS.fd not found"
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

wait_for_log_count() {
	log_file="$1"
	pattern="$2"
	expected_count="$3"
	qemu_pid="$4"
	max_wait="$5"
	wait_elapsed=0
	while [ "$wait_elapsed" -lt "$max_wait" ]; do
		actual_count=0
		if [ -r "$log_file" ]; then
			actual_count="$(grep -F -c "$pattern" "$log_file" 2>/dev/null || true)"
		fi
		[ "$actual_count" -ge "$expected_count" ] && return 0
		if ! kill -0 "$qemu_pid" 2>/dev/null; then
			wait "$qemu_pid" || true
			tail -n 120 "$log_file" >&2 2>/dev/null || true
			die "QEMU exited before marker '$pattern' appeared $expected_count times"
		fi
		sleep 1
		wait_elapsed=$((wait_elapsed + 1))
	done
	tail -n 120 "$log_file" >&2 2>/dev/null || true
	die "Timed out waiting for $expected_count occurrences of '$pattern' after ${max_wait}s"
}

wait_for_either_log_marker() {
	log_file="$1"
	first_pattern="$2"
	second_pattern="$3"
	qemu_pid="$4"
	max_wait="$5"
	wait_elapsed=0
	WAITED_LOG_MARKER=
	while [ "$wait_elapsed" -lt "$max_wait" ]; do
		if [ -r "$log_file" ] && grep -F "$first_pattern" "$log_file" >/dev/null 2>&1; then
			WAITED_LOG_MARKER="$first_pattern"
			return 0
		fi
		if [ -r "$log_file" ] && grep -F "$second_pattern" "$log_file" >/dev/null 2>&1; then
			WAITED_LOG_MARKER="$second_pattern"
			return 0
		fi
		if ! kill -0 "$qemu_pid" 2>/dev/null; then
			wait "$qemu_pid" || true
			tail -n 120 "$log_file" >&2 2>/dev/null || true
			die "QEMU exited before either marker '$first_pattern' or '$second_pattern'"
		fi
		sleep 1
		wait_elapsed=$((wait_elapsed + 1))
	done
	tail -n 120 "$log_file" >&2 2>/dev/null || true
	die "Timed out waiting for either marker '$first_pattern' or '$second_pattern' after ${max_wait}s"
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
	assert_log_contains "$log_file" "OWRT_INSTALLER_BROKER_OWNER=tty1"
	assert_log_contains "$log_file" "OpenWrt disk installer console broker is managed by /etc/inittab."
	assert_log_contains "$log_file" "OWRT_INSTALLER_UI_BACKEND=whiptail"
}

assert_framebuffer_at_least() {
	framebuffer_log="$1"
	framebuffer_min_width="$2"
	framebuffer_min_height="$3"
	framebuffer_value="$(sed -n 's/.*OWRT_INSTALLER_FRAMEBUFFER=\([0-9][0-9]*,[0-9][0-9]*\).*/\1/p' \
		"$framebuffer_log" | tail -n 1)"
	[ -n "$framebuffer_value" ] ||
		die "No graphical framebuffer marker was recorded in $framebuffer_log"
	framebuffer_width="${framebuffer_value%,*}"
	framebuffer_height="${framebuffer_value#*,}"
	if [ "$framebuffer_width" -lt "$framebuffer_min_width" ] ||
		[ "$framebuffer_height" -lt "$framebuffer_min_height" ]; then
		die "Framebuffer $framebuffer_value is below ${framebuffer_min_width}x${framebuffer_min_height}"
	fi
}

run_hardware_flag_smoke() {
	serial_log="$SMOKE_DIR/hardware-menu-iso.log"
	qemu_log="$SMOKE_DIR/hardware-menu-qemu.log"
	monitor_socket="$SMOKE_DIR/hardware-menu-monitor.sock"
	target_disk="$SMOKE_DIR/target-hardware-menu.qcow2"

	case "$QEMU_HARDWARE_WAIT" in
		''|*[!0-9]*) die "QEMU_HARDWARE_WAIT must be an integer number of seconds" ;;
	esac
	ensure_qcow2 "$target_disk"
	rm -f "$serial_log" "$qemu_log" "$monitor_socket"

	log "Starting hidden hardware-test kernel-flag smoke test"
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" -L "$QEMU_L_ARG" \
			-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
			-display none -vga std -serial "file:$serial_log" \
			-monitor "unix:$monitor_socket,server=on,wait=off" \
			-kernel "$ISO_STAGED_KERNEL" -initrd "$ISO_STAGED_INITRAMFS" \
			-append "console=tty1 console=ttyS0,115200n8 rdinit=/init owrt.mouse=1 owrt.hardware-test=1" \
			-drive "file=$target_disk,format=qcow2,if=virtio" \
			-device qemu-xhci -device usb-mouse \
			-nic user,model=e1000 -nic user,model=e1000 > "$qemu_log" 2>&1 &
	else
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" \
			-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
			-display none -vga std -serial "file:$serial_log" \
			-monitor "unix:$monitor_socket,server=on,wait=off" \
			-kernel "$ISO_STAGED_KERNEL" -initrd "$ISO_STAGED_INITRAMFS" \
			-append "console=tty1 console=ttyS0,115200n8 rdinit=/init owrt.mouse=1 owrt.hardware-test=1" \
			-drive "file=$target_disk,format=qcow2,if=virtio" \
			-device qemu-xhci -device usb-mouse \
			-nic user,model=e1000 -nic user,model=e1000 > "$qemu_log" 2>&1 &
	fi
	qemu_pid=$!

	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_HARDWARE_TEST=active" "$qemu_pid" "$QEMU_HARDWARE_WAIT"
	[ -S "$monitor_socket" ] || die "QEMU monitor socket was not created"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk" "$qemu_pid" "$QEMU_HARDWARE_WAIT"
	hmp_command "$monitor_socket" quit
	wait "$qemu_pid" || true

	assert_log_contains "$serial_log" "owrt.mouse=1"
	assert_log_contains "$serial_log" "owrt.hardware-test=1"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_UI_BACKEND=whiptail"
	assert_log_not_contains "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS="
	log "Hidden hardware-test kernel-flag smoke passed"
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
	assert_log_contains "$serial_log" "OWRT_INSTALLER_BROKER_OWNER=tty1"
	assert_framebuffer_at_least "$serial_log" 800 600
	assert_log_contains "$serial_log" "OWRT_INSTALLER_UI_BACKEND=whiptail"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk"
	log "VGA curses UI smoke passed: $screenshot"
}

run_uefi_vga_smoke() {
	serial_log="$SMOKE_DIR/uefi-vga-iso.log"
	qemu_log="$SMOKE_DIR/uefi-vga-qemu.log"
	monitor_log="$SMOKE_DIR/uefi-vga-monitor.log"
	screenshot="$SMOKE_DIR/uefi-vga-installer.ppm"
	monitor_socket="$SMOKE_DIR/uefi-vga-monitor.sock"
	target_disk="$SMOKE_DIR/target-uefi-vga.qcow2"
	vars_copy="$SMOKE_DIR/OVMF_VARS_4M-uefi-vga.fd"
	find_ovmf
	ensure_qcow2 "$target_disk"
	cp "$QEMU_OVMF_VARS" "$vars_copy"
	rm -f "$serial_log" "$qemu_log" "$monitor_log" "$screenshot" "$monitor_socket"

	set -- \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none -vga std -serial "file:$serial_log" \
		-monitor "unix:$monitor_socket,server=on,wait=off" \
		-drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$vars_copy" \
		-cdrom "$ISO_IMAGE" -boot d \
		-drive "file=$target_disk,format=qcow2,if=virtio" \
		-nic user,model=e1000 -nic user,model=e1000
	log "Starting UEFI GOP graphics and branded UI smoke test"
	start_qemu_background "$QEMU_TIMEOUT" "$qemu_log" "$@"
	qemu_pid="$QEMU_STARTED_PID"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk" \
		"$qemu_pid" "$QEMU_VGA_WAIT"
	hmp_command "$monitor_socket" "screendump $screenshot"
	hmp_command "$monitor_socket" quit
	wait "$qemu_pid" || true
	assert_nonblank_ppm "$screenshot"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_BROKER_OWNER=tty1"
	assert_framebuffer_at_least "$serial_log" 800 600
	assert_log_contains "$serial_log" "OWRT_INSTALLER_UI_BACKEND=whiptail"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk"
	log "UEFI GOP graphics and branded UI smoke passed: $screenshot"
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
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=install-type" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-profile" "$install_pid" "$QEMU_INSTALL_WAIT"
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
	assert_log_contains "$serial_log" "OWRT_INSTALLER_STORAGE_PROFILE=compatible"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_STORAGE_LAYOUT=image"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS=100"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_ROOTFS_VERIFIED_MIB="
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
	sleep 15
	{
		printf '\r'
		sleep 1
		printf '%s\r' 'cat /etc/openwrt-installer-release'
		sleep 1
		# shellcheck disable=SC2016 # Commands below are evaluated by the guest shell.
		printf '%s\r' 'sectors=$(cat /sys/class/block/vda2/size); rootfs=$(awk '\''$2 == "/" { print $3; exit }'\'' /proc/mounts)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'p3_type=$(blkid -s TYPE -o value /dev/vda3); data_mounted=0; grep " /mnt/data ext4 " /proc/mounts >/dev/null && data_mounted=1'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'guard=0; grep -q OWRT_INSTALLER_SYSUPGRADE_WRAPPER=1 /sbin/sysupgrade && guard=1'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'echo "OWRT_COMPATIBLE p3=$p3_type mounted=$data_mounted guard=$guard"'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'installed_ok=0; [ "$sectors" -gt 0 ] && [ "$rootfs" = ext4 ] && [ "$p3_type" = ext4 ] && installed_ok=1'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$installed_ok" = 1 ] && [ "$data_mounted" = 1 ] && [ "$guard" = 1 ] && echo OWRT_INSTALLED_ROOT_""OK=1'
	} |
		nc -N -U "$boot_serial_socket" >/dev/null 2>&1 || die "Could not query installed system console"
	wait_for_log_marker "$boot_serial_log" "OWRT_INSTALLED_ROOT_OK=1" "$boot_pid" "$QEMU_INSTALL_WAIT"
	hmp_command "$boot_monitor_socket" quit
	wait "$boot_pid" || true
	assert_log_contains "$boot_serial_log" "installed_by=openwrt-x86-installer"
	assert_log_contains "$boot_serial_log" "target_disk=/dev/vda"
	assert_log_contains "$boot_serial_log" "storage_layout=image"
	assert_log_contains "$boot_serial_log" "storage_profile=compatible"
	assert_log_contains "$boot_serial_log" "OWRT_COMPATIBLE p3=ext4 mounted=1 guard=1"
	assert_log_contains "$boot_serial_log" "installer_version=$INSTALLER_VERSION"
	log "Automated install and installed-system boot smoke passed"
}

drive_clean_install_flow() {
	serial_log="$1"
	monitor_socket="$2"
	install_pid="$3"
	storage_choice="$4"
	wait_limit="$5"
	target_choice="${6:-first}"

	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk" "$install_pid" "$wait_limit"
	case "$target_choice" in
		first) hmp_send_keys "$monitor_socket" ret ;;
		second) hmp_send_keys "$monitor_socket" down ret ;;
		*) die "Unsupported automated target choice: $target_choice" ;;
	esac
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=install-type" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-profile" "$install_pid" "$wait_limit"
	case "$storage_choice" in
		compatible) hmp_send_keys "$monitor_socket" ret ;;
		bounded)
			hmp_send_keys "$monitor_socket" down ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-layout" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-warning" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ret
			;;
		image)
			hmp_send_keys "$monitor_socket" down ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-layout" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-warning" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ret
			;;
		custom)
			hmp_send_keys "$monitor_socket" down down down ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-layout" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" down down ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-custom" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ctrl-u 5 1 2 0 spc shift-m i shift-b ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-data" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-data-size" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-data-label" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-data-mount" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-data" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-data-size" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ctrl-u 5 1 2 spc shift-m i shift-b ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-data-label" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-data-mount" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-data" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" down ret
			wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-warning" "$install_pid" "$wait_limit"
			hmp_send_keys "$monitor_socket" ret
			;;
		*) die "Unsupported automated storage choice: $storage_choice" ;;
	esac
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
	hmp_send_keys "$monitor_socket" shift-e shift-r shift-a shift-s shift-e spc slash d e v slash v d a ret
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS=100" "$install_pid" "$wait_limit"
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_ROOTFS_VERIFIED_MIB=" "$install_pid" "$wait_limit"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=installation-success" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=post-install-menu" "$install_pid" "$wait_limit"
	hmp_send_keys "$monitor_socket" down down ret
	sleep 2
	hmp_command "$monitor_socket" quit
	wait "$install_pid" || true
}

verify_installed_geometry() {
	layout_name="$1"
	target_disk="$2"
	vars_copy="$3"
	expected_root_sectors="$4"
	require_unallocated="$5"
	log_prefix="$6"
	expected_profile="${7:-}"
	expected_data_count="${8:-0}"
	serial_log="$SMOKE_DIR/$log_prefix-installed-boot.log"
	qemu_log="$SMOKE_DIR/$log_prefix-installed-boot-qemu.log"
	serial_socket="$SMOKE_DIR/$log_prefix-installed-serial.sock"
	monitor_socket="$SMOKE_DIR/$log_prefix-installed-monitor.sock"
	rm -f "$serial_log" "$qemu_log" "$serial_socket" "$monitor_socket"

	set -- \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none \
		-chardev "socket,id=serial0,path=$serial_socket,server=on,wait=off,logfile=$serial_log" \
		-serial chardev:serial0 -monitor "unix:$monitor_socket,server=on,wait=off" \
		-drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$vars_copy" \
		-drive "file=$target_disk,format=qcow2,if=virtio" -boot c \
		-nic user,model=e1000 -nic user,model=e1000
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$qemu_log" "$@"
	boot_pid="$QEMU_STARTED_PID"
	wait_for_log_marker "$serial_log" "Please press Enter to activate this console." "$boot_pid" "$QEMU_INSTALL_WAIT"
	{
		printf '\r'
		sleep 1
		# shellcheck disable=SC2016 # Commands below are evaluated by the guest shell.
		printf '%s\r' 'start=$(cat /sys/class/block/vda2/start); sectors=$(cat /sys/class/block/vda2/size); end=$((start + sectors - 1)); disk=$(cat /sys/class/block/vda/size)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'filesystem_kib=$(df -k / | awk '\''NR == 2 { print $2; exit }'\''); free=$((disk - end - 1))'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'meta_start=$(sed -n '\''s/^rootfs_start_sector=//p'\'' /etc/openwrt-installer-release); meta_end=$(sed -n '\''s/^rootfs_end_sector=//p'\'' /etc/openwrt-installer-release)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'meta_layout=$(sed -n '\''s/^storage_layout=//p'\'' /etc/openwrt-installer-release); uuid=$(blkid -s PARTUUID -o value /dev/vda2)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'meta_profile=$(sed -n '\''s/^storage_profile=//p'\'' /etc/openwrt-installer-release); meta_data_count=$(sed -n '\''s/^data_partition_count=//p'\'' /etc/openwrt-installer-release)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'partuuid_ok=0; grep -q "root=PARTUUID=$uuid" /proc/cmdline && partuuid_ok=1; mount_ok=0; grep " / ext4 " /proc/mounts >/dev/null && mount_ok=1'
		sleep 1
		printf 'expected_layout=%s; expected_sectors=%s; need_free=%s; expected_profile=%s; expected_data_count=%s\r' \
			"$layout_name" "${expected_root_sectors:-0}" "$require_unallocated" \
			"$expected_profile" "$expected_data_count"
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'size_ok=1; [ "$expected_sectors" = 0 ] || [ "$sectors" = "$expected_sectors" ] || size_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'free_ok=1; [ "$need_free" = 0 ] || [ "$free" -gt 1048576 ] || free_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'data_ok=1; [ "$meta_profile" = "$expected_profile" ] && [ "$meta_data_count" = "$expected_data_count" ] || data_ok=0'
		sleep 1
		data_number=3
		data_last=$((expected_data_count + 2))
		while [ "$data_number" -le "$data_last" ]; do
			printf 'number=%s; section=partition%s; dev=/dev/vda%s\r' \
				"$data_number" "$data_number" "$data_number"
			sleep 1
			# shellcheck disable=SC2016
			printf '%s\r' 'meta_uuid=$(uci -q get "owrt-installer.$section.uuid"); meta_label=$(uci -q get "owrt-installer.$section.label")'
			sleep 1
			# shellcheck disable=SC2016
			printf '%s\r' 'target=$(uci -q get "fstab.owrt_data_$number.target"); actual_uuid=$(blkid -s UUID -o value "$dev")'
			sleep 1
			# shellcheck disable=SC2016
			printf '%s\r' 'actual_label=$(blkid -s LABEL -o value "$dev"); actual_type=$(blkid -s TYPE -o value "$dev")'
			sleep 1
			# shellcheck disable=SC2016
			printf '%s\r' 'grep " $target ext4 " /proc/mounts >/dev/null || data_ok=0'
			sleep 1
			# shellcheck disable=SC2016
			printf '%s\r' '[ "$actual_type" = ext4 ] && [ "$actual_uuid" = "$meta_uuid" ] && [ "$actual_label" = "$meta_label" ] || data_ok=0'
			sleep 1
			data_number=$((data_number + 1))
		done
		# shellcheck disable=SC2016
		printf '%s\r' 'echo "OWRT_GEOMETRY layout=$meta_layout profile=$meta_profile data=$meta_data_count data_ok=$data_ok"'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'echo "OWRT_GEOMETRY_DETAIL start=$start sectors=$sectors free=$free partuuid=$partuuid_ok mount=$mount_ok"'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'geometry_ok=1; [ "$meta_layout" = "$expected_layout" ] && [ "$meta_start" = "$start" ] && [ "$meta_end" = "$end" ] || geometry_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$filesystem_kib" -gt 0 ] && [ "$partuuid_ok" = 1 ] && [ "$mount_ok" = 1 ] || geometry_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$size_ok" = 1 ] && [ "$free_ok" = 1 ] && [ "$data_ok" = 1 ] || geometry_ok=0; [ "$geometry_ok" = 1 ] && echo OWRT_GEOMETRY_""OK=1'
	} | nc -N -U "$serial_socket" >/dev/null 2>&1 ||
		die "Could not query $layout_name installed geometry"
	wait_for_log_marker "$serial_log" "OWRT_GEOMETRY_OK=1" "$boot_pid" "$QEMU_INSTALL_WAIT"
	hmp_command "$monitor_socket" quit
	wait "$boot_pid" || true
	assert_log_contains "$serial_log" "OWRT_GEOMETRY layout=$layout_name profile=$expected_profile data=$expected_data_count data_ok=1"
	assert_log_contains "$serial_log" "OWRT_GEOMETRY_DETAIL"
	assert_log_contains "$serial_log" "partuuid=1 mount=1"
}

verify_host_gpt_tail() {
	target_disk="$1"
	log_prefix="$2"
	raw_disk="$SMOKE_DIR/$log_prefix-gpt.raw"
	fdisk_report="$SMOKE_DIR/$log_prefix-gpt-fdisk.log"
	sfdisk_report="$SMOKE_DIR/$log_prefix-gpt-sfdisk.log"
	layout_report="$SMOKE_DIR/$log_prefix-gpt-layout.sfdisk"
	layout_raw_report="$layout_report.raw"
	rm -f "$raw_disk" "$fdisk_report" "$sfdisk_report" "$layout_report" \
		"$layout_raw_report"

	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		env $QEMU_ENV_PREFIX "$QEMU_IMG" convert -f qcow2 -O raw -S 4k "$target_disk" "$raw_disk" ||
			die "Could not convert installed disk for GPT validation"
	else
		"$QEMU_IMG" convert -f qcow2 -O raw -S 4k "$target_disk" "$raw_disk" ||
			die "Could not convert installed disk for GPT validation"
	fi
	if ! LC_ALL=C fdisk -l "$raw_disk" > "$fdisk_report" 2>&1; then
		rm -f "$raw_disk"
		die "fdisk rejected the installed GPT; see $fdisk_report"
	fi
	if grep -E 'GPT PMBR size mismatch|backup GPT.*(corrupt|not on the end)' \
		"$fdisk_report" >/dev/null 2>&1; then
		rm -f "$raw_disk"
		die "The installed backup GPT is not at the end of the disk; see $fdisk_report"
	fi
	grep -F 'Disklabel type: gpt' "$fdisk_report" >/dev/null 2>&1 || {
		rm -f "$raw_disk"
		die "Installed disk is not reported as GPT; see $fdisk_report"
	}
	if ! LC_ALL=C sfdisk --verify "$raw_disk" > "$sfdisk_report" 2>&1; then
		rm -f "$raw_disk"
		die "sfdisk rejected the installed GPT; see $sfdisk_report"
	fi
	if ! LC_ALL=C sfdisk --dump "$raw_disk" > "$layout_raw_report" 2>&1; then
		rm -f "$raw_disk"
		die "sfdisk could not dump the installed GPT; see $layout_raw_report"
	fi
	if ! sed -e '/^device: /d' -e "s|^$raw_disk|device|" \
		"$layout_raw_report" > "$layout_report"; then
		rm -f "$raw_disk" "$layout_raw_report"
		die "Could not normalize the installed GPT dump"
	fi
	rm -f "$raw_disk" "$layout_raw_report"
	log "Installed primary and backup GPT validation passed"
}

run_storage_layout_smoke() {
	layout_name="$1"
	expected_layout="$layout_name"
	case "$layout_name" in
		bounded)
			disk_size=6G
			expected_root_sectors=8388608
			require_unallocated=1
			;;
		image)
			disk_size=2G
			expected_root_sectors=""
			require_unallocated=1
			;;
		custom)
			disk_size=8G
			expected_root_sectors=10485760
			require_unallocated=1
			expected_layout=bounded
			expected_profile=custom
			expected_data_count=2
			;;
		*) die "Unsupported storage-layout QEMU mode: $layout_name" ;;
	esac
	case "$layout_name" in
		bounded|image) expected_profile=expanded; expected_data_count=0 ;;
	esac
	serial_log="$SMOKE_DIR/storage-$layout_name-iso.log"
	qemu_log="$SMOKE_DIR/storage-$layout_name-qemu.log"
	monitor_socket="$SMOKE_DIR/storage-$layout_name-monitor.sock"
	target_disk="$SMOKE_DIR/target-storage-$layout_name.qcow2"
	vars_copy="$SMOKE_DIR/OVMF_VARS_4M-storage-$layout_name.fd"
	rm -f "$serial_log" "$qemu_log" "$monitor_socket" "$vars_copy"
	create_qcow2 "$target_disk" "$disk_size"
	find_ovmf
	cp "$QEMU_OVMF_VARS" "$vars_copy"

	log "Starting UEFI $layout_name partition-layout installation smoke test"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$qemu_log" \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none -vga std -serial "file:$serial_log" \
		-monitor "unix:$monitor_socket,server=on,wait=off" \
		-drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$vars_copy" \
		-cdrom "$ISO_IMAGE" -boot d \
		-drive "file=$target_disk,format=qcow2,if=virtio" \
		-nic user,model=e1000 -nic user,model=e1000
	install_pid="$QEMU_STARTED_PID"
	drive_clean_install_flow "$serial_log" "$monitor_socket" "$install_pid" "$layout_name" "$QEMU_INSTALL_WAIT"

	assert_log_contains "$serial_log" "OWRT_INSTALLER_STORAGE_LAYOUT=$expected_layout"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_STORAGE_PROFILE=$expected_profile"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_ROOTFS_VERIFIED_MIB="
	assert_log_not_contains "$serial_log" "Installation failed"
	verify_host_gpt_tail "$target_disk" "storage-$layout_name"
	verify_installed_geometry "$expected_layout" "$target_disk" "$vars_copy" \
		"$expected_root_sectors" "$require_unallocated" "storage-$layout_name" \
		"$expected_profile" "$expected_data_count"
	log "UEFI $layout_name partition-layout install and reboot smoke passed"
}

run_safe_upgrade_smoke() {
	target_disk="$SMOKE_DIR/target-safe-upgrade.qcow2"
	vars_copy="$SMOKE_DIR/OVMF_VARS_4M-safe-upgrade.fd"
	baseline_serial_log="$SMOKE_DIR/safe-upgrade-baseline-iso.log"
	baseline_qemu_log="$SMOKE_DIR/safe-upgrade-baseline-qemu.log"
	baseline_monitor_socket="$SMOKE_DIR/safe-upgrade-baseline-monitor.sock"
	source_serial_log="$SMOKE_DIR/safe-upgrade-source-boot.log"
	source_qemu_log="$SMOKE_DIR/safe-upgrade-source-boot-qemu.log"
	source_serial_socket="$SMOKE_DIR/safe-upgrade-source-serial.sock"
	source_monitor_socket="$SMOKE_DIR/safe-upgrade-source-monitor.sock"
	upgrade_serial_log="$SMOKE_DIR/safe-upgrade-iso.log"
	upgrade_qemu_log="$SMOKE_DIR/safe-upgrade-qemu.log"
	upgrade_monitor_socket="$SMOKE_DIR/safe-upgrade-monitor.sock"
	verify_serial_log="$SMOKE_DIR/safe-upgrade-installed-boot.log"
	verify_qemu_log="$SMOKE_DIR/safe-upgrade-installed-boot-qemu.log"
	verify_serial_socket="$SMOKE_DIR/safe-upgrade-installed-serial.sock"
	verify_monitor_socket="$SMOKE_DIR/safe-upgrade-installed-monitor.sock"
	rm -f "$target_disk" "$vars_copy" "$baseline_serial_log" \
		"$baseline_qemu_log" "$baseline_monitor_socket" "$source_serial_log" \
		"$source_qemu_log" "$source_serial_socket" "$source_monitor_socket" \
		"$upgrade_serial_log" "$upgrade_qemu_log" "$upgrade_monitor_socket" \
		"$verify_serial_log" "$verify_qemu_log" "$verify_serial_socket" \
		"$verify_monitor_socket"
	create_qcow2 "$target_disk" 6G
	find_ovmf
	cp "$QEMU_OVMF_VARS" "$vars_copy"

	log "Creating a compatible managed installation for Safe Upgrade smoke"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$baseline_qemu_log" \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none -vga std -serial "file:$baseline_serial_log" \
		-monitor "unix:$baseline_monitor_socket,server=on,wait=off" \
		-drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$vars_copy" \
		-cdrom "$ISO_IMAGE" -boot d \
		-drive "file=$target_disk,format=qcow2,if=virtio" \
		-nic user,model=e1000 -nic user,model=e1000
	baseline_pid="$QEMU_STARTED_PID"
	drive_clean_install_flow "$baseline_serial_log" "$baseline_monitor_socket" \
		"$baseline_pid" compatible "$QEMU_INSTALL_WAIT"
	assert_log_contains "$baseline_serial_log" "OWRT_INSTALLER_STORAGE_PROFILE=compatible"
	assert_log_not_contains "$baseline_serial_log" "Installation failed"
	verify_host_gpt_tail "$target_disk" safe-upgrade-baseline

	log "Booting the managed installation and writing configuration and data evidence"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$source_qemu_log" \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none \
		-chardev "socket,id=serial0,path=$source_serial_socket,server=on,wait=off,logfile=$source_serial_log" \
		-serial chardev:serial0 -monitor "unix:$source_monitor_socket,server=on,wait=off" \
		-drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$vars_copy" \
		-drive "file=$target_disk,format=qcow2,if=virtio" -boot c \
		-nic user,model=e1000 -nic user,model=e1000
	source_pid="$QEMU_STARTED_PID"
	wait_for_log_marker "$source_serial_log" "Please press Enter to activate this console." \
		"$source_pid" "$QEMU_INSTALL_WAIT"
	sleep 15
	{
		printf '\r'
		sleep 1
		printf '%s\r' 'uci set system.@system[0].hostname="safe-upgrade-source"; uci commit system'
		sleep 1
		printf '%s\r' 'uci set network.lan.ipaddr="10.55.66.1"; uci commit network'
		sleep 1
		# shellcheck disable=SC2016 # Commands below are evaluated by the guest shell.
		printf '%s\r' 'p1_start=$(cat /sys/class/block/vda1/start); p1_size=$(cat /sys/class/block/vda1/size); p2_start=$(cat /sys/class/block/vda2/start); p2_size=$(cat /sys/class/block/vda2/size)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'p3_start=$(cat /sys/class/block/vda3/start); p3_size=$(cat /sys/class/block/vda3/size); p3_uuid=$(blkid -s UUID -o value /dev/vda3); p3_label=$(blkid -s LABEL -o value /dev/vda3)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'source_ok=0; grep " /mnt/data ext4 " /proc/mounts >/dev/null && [ -n "$p3_uuid" ] && source_ok=1'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$source_ok" = 1 ] && echo "$p1_start|$p1_size|$p2_start|$p2_size|$p3_start|$p3_size|$p3_uuid|$p3_label" > /mnt/data/safe-upgrade-layout'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$source_ok" = 1 ] && echo hellforge-safe-upgrade-data > /mnt/data/safe-upgrade-evidence'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'if [ "$source_ok" = 1 ]; then sync; echo OWRT_SAFE_UPGRADE_SOURCE_READY=1; else echo OWRT_SAFE_UPGRADE_SOURCE_FAILED=1; fi; poweroff'
	} | nc -N -U "$source_serial_socket" >/dev/null 2>&1 ||
		die "Could not prepare Safe Upgrade source evidence"
	wait_for_log_marker "$source_serial_log" "OWRT_SAFE_UPGRADE_SOURCE_READY=1" \
		"$source_pid" "$QEMU_INSTALL_WAIT"
	wait "$source_pid" || true

	log "Running Hellforge Safe Upgrade against the managed installation"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$upgrade_qemu_log" \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none -vga std -serial "file:$upgrade_serial_log" \
		-monitor "unix:$upgrade_monitor_socket,server=on,wait=off" \
		-kernel "$ISO_STAGED_KERNEL" -initrd "$ISO_STAGED_INITRAMFS" \
		-append "console=tty1 console=ttyS0,115200n8 rdinit=/init owrt.mouse=1" \
		-drive "file=$target_disk,format=qcow2,if=virtio" \
		-nic user,model=e1000 -nic user,model=e1000
	upgrade_pid="$QEMU_STARTED_PID"
	wait_for_ui_marker "$upgrade_serial_log" "OWRT_INSTALLER_UI_READY=target-disk" \
		"$upgrade_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$upgrade_monitor_socket" ret
	wait_for_ui_marker "$upgrade_serial_log" "OWRT_INSTALLER_UI_READY=existing-system-action" \
		"$upgrade_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$upgrade_monitor_socket" ret
	wait_for_ui_marker "$upgrade_serial_log" "OWRT_INSTALLER_UI_READY=rescue-scope" \
		"$upgrade_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$upgrade_monitor_socket" ret
	wait_for_ui_marker "$upgrade_serial_log" "OWRT_INSTALLER_UI_READY=config-import-network" \
		"$upgrade_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$upgrade_monitor_socket" ret
	wait_for_ui_marker "$upgrade_serial_log" "OWRT_INSTALLER_UI_READY=rescue-ready" \
		"$upgrade_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$upgrade_monitor_socket" ret
	wait_for_log_marker "$upgrade_serial_log" "OWRT_INSTALLER_SAFE_UPGRADE_READY=compatible:1" \
		"$upgrade_pid" "$QEMU_INSTALL_WAIT"
	wait_for_ui_marker "$upgrade_serial_log" "OWRT_INSTALLER_UI_READY=review-summary" \
		"$upgrade_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$upgrade_monitor_socket" ret
	wait_for_ui_marker "$upgrade_serial_log" "OWRT_INSTALLER_UI_READY=review-action" \
		"$upgrade_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$upgrade_monitor_socket" ret
	wait_for_ui_marker "$upgrade_serial_log" "OWRT_INSTALLER_UI_READY=final-upgrade-info" \
		"$upgrade_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$upgrade_monitor_socket" ret
	wait_for_ui_marker "$upgrade_serial_log" "OWRT_INSTALLER_UI_READY=exact-upgrade" \
		"$upgrade_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$upgrade_monitor_socket" shift-u shift-p shift-g shift-r shift-a shift-d shift-e \
		spc slash d e v slash v d a ret
	wait_for_log_marker "$upgrade_serial_log" "OWRT_INSTALLER_SAFE_UPGRADE_TABLE_PRESERVED=1" \
		"$upgrade_pid" "$QEMU_INSTALL_WAIT"
	wait_for_ui_marker "$upgrade_serial_log" "OWRT_INSTALLER_UI_READY=installation-success" \
		"$upgrade_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$upgrade_monitor_socket" ret
	wait_for_ui_marker "$upgrade_serial_log" "OWRT_INSTALLER_UI_READY=post-install-menu" \
		"$upgrade_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$upgrade_monitor_socket" down down ret
	sleep 2
	hmp_command "$upgrade_monitor_socket" quit
	wait "$upgrade_pid" || true

	[ "$(grep -c -F 'OWRT_INSTALLER_SAFE_UPGRADE_DATA_VERIFIED=1' "$upgrade_serial_log")" -eq 3 ] ||
		die "Safe Upgrade did not verify the data partition at all three write boundaries"
	assert_log_not_contains "$upgrade_serial_log" "OWRT_INSTALLER_WRITE_PROGRESS="
	assert_log_not_contains "$upgrade_serial_log" "Installation failed"
	verify_host_gpt_tail "$target_disk" safe-upgrade-final

	log "Booting the Safe Upgrade result and validating preserved state"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$verify_qemu_log" \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none \
		-chardev "socket,id=serial0,path=$verify_serial_socket,server=on,wait=off,logfile=$verify_serial_log" \
		-serial chardev:serial0 -monitor "unix:$verify_monitor_socket,server=on,wait=off" \
		-drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$vars_copy" \
		-drive "file=$target_disk,format=qcow2,if=virtio" -boot c \
		-nic user,model=e1000 -nic user,model=e1000
	verify_pid="$QEMU_STARTED_PID"
	wait_for_log_marker "$verify_serial_log" "Please press Enter to activate this console." \
		"$verify_pid" "$QEMU_INSTALL_WAIT"
	sleep 15
	{
		printf '\r'
		sleep 1
		# shellcheck disable=SC2016 # Commands below are evaluated by the guest shell.
		printf '%s\r' 'IFS="|" read -r old_p1_start old_p1_size old_p2_start old_p2_size old_p3_start old_p3_size old_p3_uuid old_p3_label < /mnt/data/safe-upgrade-layout'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'p1_start=$(cat /sys/class/block/vda1/start); p1_size=$(cat /sys/class/block/vda1/size); p2_start=$(cat /sys/class/block/vda2/start); p2_size=$(cat /sys/class/block/vda2/size)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'p3_start=$(cat /sys/class/block/vda3/start); p3_size=$(cat /sys/class/block/vda3/size)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'p3_uuid=$(blkid -s UUID -o value /dev/vda3); p3_label=$(blkid -s LABEL -o value /dev/vda3); hostname=$(uci -q get system.@system[0].hostname); lan=$(uci -q get network.lan.ipaddr)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'mode=$(sed -n '\''s/^install_mode=//p'\'' /etc/openwrt-installer-release); scope=$(sed -n '\''s/^rescue_scope=//p'\'' /etc/openwrt-installer-release)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'network=$(sed -n '\''s/^network_source=//p'\'' /etc/openwrt-installer-release)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'layout_ok=1; [ "$p1_start" = "$old_p1_start" ] && [ "$p1_size" = "$old_p1_size" ] || layout_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$p2_start" = "$old_p2_start" ] && [ "$p2_size" = "$old_p2_size" ] || layout_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$p3_start" = "$old_p3_start" ] && [ "$p3_size" = "$old_p3_size" ] || layout_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$p3_uuid" = "$old_p3_uuid" ] && [ "$p3_label" = "$old_p3_label" ] || layout_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'data_ok=0; [ "$(cat /mnt/data/safe-upgrade-evidence 2>/dev/null)" = hellforge-safe-upgrade-data ] && data_ok=1'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'grep " /mnt/data ext4 " /proc/mounts >/dev/null || data_ok=0; guard=0; grep -q OWRT_INSTALLER_SYSUPGRADE_WRAPPER=1 /sbin/sysupgrade && guard=1'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'echo "OWRT_SAFE_UPGRADE_RESULT layout=$layout_ok data=$data_ok hostname=$hostname lan=$lan mode=$mode scope=$scope network=$network guard=$guard"'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'identity_ok=0; [ "$hostname" = safe-upgrade-source ] && [ "$lan" = 10.55.66.1 ] && [ "$mode" = safe-upgrade ] && identity_ok=1'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$scope" = config-only ] && [ "$network" = imported ] || identity_ok=0; [ "$layout_ok" = 1 ] && [ "$data_ok" = 1 ] && [ "$identity_ok" = 1 ] && [ "$guard" = 1 ] && echo OWRT_SAFE_UPGRADE_""OK=1'
	} | nc -N -U "$verify_serial_socket" >/dev/null 2>&1 ||
		die "Could not query the Safe Upgrade result"
	wait_for_log_marker "$verify_serial_log" "OWRT_SAFE_UPGRADE_OK=1" \
		"$verify_pid" "$QEMU_INSTALL_WAIT"
	hmp_command "$verify_monitor_socket" quit
	wait "$verify_pid" || true
	assert_log_contains "$verify_serial_log" \
		"OWRT_SAFE_UPGRADE_RESULT layout=1 data=1 hostname=safe-upgrade-source lan=10.55.66.1 mode=safe-upgrade scope=config-only network=imported guard=1"
	log "Hellforge Safe Upgrade QEMU smoke passed"
}

send_standard_upgrade_validation() {
	serial_socket="$1"
	cycle="$2"
	{
		printf '\r'
		sleep 1
		# shellcheck disable=SC2016 # Commands below are evaluated by the guest shell.
		printf '%s\r' 'wait_i=0; while ! grep " /mnt/data ext4 " /proc/mounts >/dev/null; do sleep 1; wait_i=$((wait_i + 1)); [ "$wait_i" -lt 120 ] || break; done'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'p3_ready=0; grep " /mnt/data ext4 " /proc/mounts >/dev/null && p3_ready=1'
		sleep 1
		# shellcheck disable=SC2016 # Commands below are evaluated by the guest shell.
		printf '%s\r' 'IFS="|" read -r old_p1_start old_p1_size old_p2_start old_p2_size old_p3_start old_p3_size old_p3_uuid < /mnt/data/standard-upgrade-layout'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'p1_start=$(cat /sys/class/block/vda1/start); p1_size=$(cat /sys/class/block/vda1/size); p2_start=$(cat /sys/class/block/vda2/start); p2_size=$(cat /sys/class/block/vda2/size)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'p3_start=$(cat /sys/class/block/vda3/start); p3_size=$(cat /sys/class/block/vda3/size); p3_uuid=$(blkid -s UUID -o value /dev/vda3)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'layout_ok=1; [ "$p1_start" = "$old_p1_start" ] && [ "$p1_size" = "$old_p1_size" ] || layout_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$p2_start" = "$old_p2_start" ] && [ "$p2_size" = "$old_p2_size" ] || layout_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$p3_start" = "$old_p3_start" ] && [ "$p3_size" = "$old_p3_size" ] && [ "$p3_uuid" = "$old_p3_uuid" ] || layout_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'data_ok=0; [ "$(cat /mnt/data/standard-upgrade-evidence 2>/dev/null)" = hellforge-standard-upgrade-data ] && data_ok=1'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'grep " /mnt/data ext4 " /proc/mounts >/dev/null || data_ok=0; guard=0; grep -q OWRT_INSTALLER_SYSUPGRADE_WRAPPER=1 /sbin/sysupgrade && guard=1'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'hostname=$(uci -q get system.@system[0].hostname); dmesg_ok=1; dmesg | grep -Ei '\''vda3.*(error|corrupt|checksum|i/o failure|aborting)'\'' >/dev/null && dmesg_ok=0'
		sleep 1
		printf 'cycle=%s\r' "$cycle"
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'echo "OWRT_STANDARD_UPGRADE_RESULT cycle=$cycle layout=$layout_ok data=$data_ok hostname=$hostname guard=$guard dmesg=$dmesg_ok"'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'cycle_ok=1; [ "$p3_ready" = 1 ] && [ "$layout_ok" = 1 ] && [ "$data_ok" = 1 ] || cycle_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$hostname" = standard-upgrade-source ] || cycle_ok=0'
		sleep 1
		# shellcheck disable=SC2016
		printf '[ "$guard" = 1 ] && [ "$dmesg_ok" = 1 ] && [ "$cycle_ok" = 1 ] && echo OWRT_STANDARD_UPGRADE_CYCLE_%s_""OK=1\r' "$cycle"
	} | nc -N -U "$serial_socket" >/dev/null 2>&1 ||
		die "Could not validate standard sysupgrade cycle $cycle"
}

run_standard_sysupgrade_smoke() {
	target_disk="$SMOKE_DIR/target-standard-upgrade.qcow2"
	vars_copy="$SMOKE_DIR/OVMF_VARS_4M-standard-upgrade.fd"
	transport_dir="$SMOKE_DIR/standard-upgrade-transport"
	transport_image="$SMOKE_DIR/standard-upgrade-transport.ext4"
	baseline_serial_log="$SMOKE_DIR/standard-upgrade-baseline-iso.log"
	baseline_qemu_log="$SMOKE_DIR/standard-upgrade-baseline-qemu.log"
	baseline_monitor_socket="$SMOKE_DIR/standard-upgrade-baseline-monitor.sock"
	standard_serial_log="$SMOKE_DIR/standard-upgrade-boot.log"
	standard_qemu_log="$SMOKE_DIR/standard-upgrade-boot-qemu.log"
	standard_serial_socket="$SMOKE_DIR/standard-upgrade-serial.sock"
	standard_monitor_socket="$SMOKE_DIR/standard-upgrade-monitor.sock"
	rm -rf "$transport_dir"
	rm -f "$target_disk" "$vars_copy" "$transport_image" "$baseline_serial_log" \
		"$baseline_qemu_log" "$baseline_monitor_socket" "$standard_serial_log" \
		"$standard_qemu_log" "$standard_serial_socket" "$standard_monitor_socket"
	mkdir -p "$transport_dir"
	cp "$TARGET_IMAGE" "$transport_dir/openwrt-target.img.gz"
	truncate -s 64M "$transport_image"
	mkfs.ext4 -q -F -d "$transport_dir" "$transport_image"
	create_qcow2 "$target_disk" 6G
	find_ovmf
	cp "$QEMU_OVMF_VARS" "$vars_copy"

	log "Creating a compatible managed installation for sequential sysupgrade smoke"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$baseline_qemu_log" \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none -vga std -serial "file:$baseline_serial_log" \
		-monitor "unix:$baseline_monitor_socket,server=on,wait=off" \
		-drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$vars_copy" \
		-cdrom "$ISO_IMAGE" -boot d \
		-drive "file=$target_disk,format=qcow2,if=virtio" \
		-nic user,model=e1000 -nic user,model=e1000
	baseline_pid="$QEMU_STARTED_PID"
	drive_clean_install_flow "$baseline_serial_log" "$baseline_monitor_socket" \
		"$baseline_pid" compatible "$QEMU_INSTALL_WAIT"
	assert_log_not_contains "$baseline_serial_log" "Installation failed"
	verify_host_gpt_tail "$target_disk" standard-upgrade-baseline

	log "Booting the managed installation for two standard sysupgrade cycles"
	start_qemu_background "$QEMU_STANDARD_UPGRADE_TIMEOUT" "$standard_qemu_log" \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_STANDARD_UPGRADE_SMP" \
		-display none \
		-chardev "socket,id=serial0,path=$standard_serial_socket,server=on,wait=off,logfile=$standard_serial_log" \
		-serial chardev:serial0 -monitor "unix:$standard_monitor_socket,server=on,wait=off" \
		-drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$vars_copy" \
		-drive "file=$target_disk,format=qcow2,if=virtio" \
		-drive "file=$transport_image,format=raw,if=virtio,readonly=on" -boot c \
		-nic user,model=e1000 -nic user,model=e1000
	upgrade_pid="$QEMU_STARTED_PID"
	wait_for_log_count "$standard_serial_log" "Please press Enter to activate this console." 1 \
		"$upgrade_pid" "$QEMU_STANDARD_UPGRADE_WAIT"
	printf '\r' | nc -N -U "$standard_serial_socket" >/dev/null 2>&1 ||
		die "Could not activate the standard sysupgrade console"
	wait_for_log_count "$standard_serial_log" "root login on 'ttyS0'" 1 \
		"$upgrade_pid" "$QEMU_STANDARD_UPGRADE_WAIT"
	sleep 2
	{
		# shellcheck disable=SC2016
		printf '%s\r' 'wait_i=0; while ! grep " /mnt/data ext4 " /proc/mounts >/dev/null; do sleep 1; wait_i=$((wait_i + 1)); [ "$wait_i" -lt 120 ] || break; done'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'p3_ready=0; grep " /mnt/data ext4 " /proc/mounts >/dev/null && p3_ready=1'
		sleep 1
		printf '%s\r' 'uci set system.@system[0].hostname="standard-upgrade-source"; uci commit system'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'p1_start=$(cat /sys/class/block/vda1/start); p1_size=$(cat /sys/class/block/vda1/size); p2_start=$(cat /sys/class/block/vda2/start); p2_size=$(cat /sys/class/block/vda2/size)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'p3_start=$(cat /sys/class/block/vda3/start); p3_size=$(cat /sys/class/block/vda3/size); p3_uuid=$(blkid -s UUID -o value /dev/vda3)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$p3_ready" = 1 ] && echo "$p1_start|$p1_size|$p2_start|$p2_size|$p3_start|$p3_size|$p3_uuid" > /mnt/data/standard-upgrade-layout'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$p3_ready" = 1 ] && echo hellforge-standard-upgrade-data > /mnt/data/standard-upgrade-evidence; sync'
		sleep 1
		printf '%s\r' 'mkdir -p /mnt/candidate; mount -t ext4 -o ro /dev/vdb /mnt/candidate'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' '[ "$p3_ready" = 1 ] && sysupgrade -T /mnt/candidate/openwrt-target.img.gz && echo OWRT_STANDARD_PREFLIGHT_""1=1'
	} | nc -N -U "$standard_serial_socket" >/dev/null 2>&1 ||
		die "Could not prepare the first standard sysupgrade cycle"
	wait_for_log_marker "$standard_serial_log" "OWRT_STANDARD_PREFLIGHT_1=1" \
		"$upgrade_pid" "$QEMU_STANDARD_UPGRADE_WAIT"
	sleep 2
	printf '%s\r' 'sysupgrade /mnt/candidate/openwrt-target.img.gz' |
		nc -N -U "$standard_serial_socket" >/dev/null 2>&1 || die "Could not start standard sysupgrade cycle 1"
	wait_for_log_count "$standard_serial_log" "Please press Enter to activate this console." 2 \
		"$upgrade_pid" "$QEMU_STANDARD_UPGRADE_WAIT"
	printf '\r' | nc -N -U "$standard_serial_socket" >/dev/null 2>&1 ||
		die "Could not activate the console after standard sysupgrade cycle 1"
	wait_for_log_count "$standard_serial_log" "root login on 'ttyS0'" 2 \
		"$upgrade_pid" "$QEMU_STANDARD_UPGRADE_WAIT"
	sleep 2
	send_standard_upgrade_validation "$standard_serial_socket" 1
	wait_for_log_marker "$standard_serial_log" "OWRT_STANDARD_UPGRADE_CYCLE_1_OK=1" \
		"$upgrade_pid" "$QEMU_STANDARD_UPGRADE_WAIT"
	sleep 2
	{
		printf '%s\r' 'mkdir -p /mnt/candidate; mount -t ext4 -o ro /dev/vdb /mnt/candidate'
		sleep 1
		printf '%s\r' 'sysupgrade -T /mnt/candidate/openwrt-target.img.gz && echo OWRT_STANDARD_PREFLIGHT_""2=1'
	} | nc -N -U "$standard_serial_socket" >/dev/null 2>&1 ||
		die "Could not prepare the second standard sysupgrade cycle"
	wait_for_log_marker "$standard_serial_log" "OWRT_STANDARD_PREFLIGHT_2=1" \
		"$upgrade_pid" "$QEMU_STANDARD_UPGRADE_WAIT"
	sleep 2
	printf '%s\r' 'sysupgrade /mnt/candidate/openwrt-target.img.gz' |
		nc -N -U "$standard_serial_socket" >/dev/null 2>&1 || die "Could not start standard sysupgrade cycle 2"
	wait_for_log_count "$standard_serial_log" "Please press Enter to activate this console." 3 \
		"$upgrade_pid" "$QEMU_STANDARD_UPGRADE_WAIT"
	printf '\r' | nc -N -U "$standard_serial_socket" >/dev/null 2>&1 ||
		die "Could not activate the console after standard sysupgrade cycle 2"
	wait_for_log_count "$standard_serial_log" "root login on 'ttyS0'" 3 \
		"$upgrade_pid" "$QEMU_STANDARD_UPGRADE_WAIT"
	sleep 2
	send_standard_upgrade_validation "$standard_serial_socket" 2
	wait_for_log_marker "$standard_serial_log" "OWRT_STANDARD_UPGRADE_CYCLE_2_OK=1" \
		"$upgrade_pid" "$QEMU_STANDARD_UPGRADE_WAIT"
	hmp_command "$standard_monitor_socket" quit
	wait "$upgrade_pid" || true

	[ "$(grep -F -c 'Writing image to /dev/vda1' "$standard_serial_log")" -ge 2 ] ||
		die "Standard sysupgrade did not prove partition-wise boot writes in both cycles"
	[ "$(grep -F -c 'Writing image to /dev/vda2' "$standard_serial_log")" -ge 2 ] ||
		die "Standard sysupgrade did not prove partition-wise root writes in both cycles"
	assert_log_not_contains "$standard_serial_log" "Partition layout has changed. Full image will be written."
	assert_log_not_contains "$standard_serial_log" "Kernel panic"
	assert_log_not_contains "$standard_serial_log" "Oops:"
	assert_log_not_contains "$standard_serial_log" "BUG:"
	assert_log_contains "$standard_serial_log" "OWRT_STANDARD_UPGRADE_RESULT cycle=1 layout=1 data=1 hostname=standard-upgrade-source guard=1 dmesg=1"
	assert_log_contains "$standard_serial_log" "OWRT_STANDARD_UPGRADE_RESULT cycle=2 layout=1 data=1 hostname=standard-upgrade-source guard=1 dmesg=1"
	verify_host_gpt_tail "$target_disk" standard-upgrade-final
	cmp -s "$SMOKE_DIR/standard-upgrade-baseline-gpt-layout.sfdisk" \
		"$SMOKE_DIR/standard-upgrade-final-gpt-layout.sfdisk" ||
		die "Standard sysupgrade changed the managed GPT layout"
	log "Two sequential guarded standard sysupgrade cycles passed"
}

verify_rescued_system() {
	target_disk="$1"
	vars_copy="$2"
	expected_scope="$3"
	serial_log="$SMOKE_DIR/rescue-$expected_scope-installed-boot.log"
	qemu_log="$SMOKE_DIR/rescue-$expected_scope-installed-boot-qemu.log"
	serial_socket="$SMOKE_DIR/rescue-$expected_scope-installed-serial.sock"
	monitor_socket="$SMOKE_DIR/rescue-$expected_scope-installed-monitor.sock"
	rm -f "$serial_log" "$qemu_log" "$serial_socket" "$monitor_socket"

	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$qemu_log" \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none \
		-chardev "socket,id=serial0,path=$serial_socket,server=on,wait=off,logfile=$serial_log" \
		-serial chardev:serial0 -monitor "unix:$monitor_socket,server=on,wait=off" \
		-drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$vars_copy" \
		-drive "file=$target_disk,format=qcow2,if=virtio" -boot c \
		-nic user,model=e1000 -nic user,model=e1000
	boot_pid="$QEMU_STARTED_PID"
	wait_for_log_marker "$serial_log" "Please press Enter to activate this console." "$boot_pid" "$QEMU_INSTALL_WAIT"
	{
		printf '\r'
		sleep 1
		# shellcheck disable=SC2016 # Commands below are evaluated by the guest shell.
		printf '%s\r' 'hostname=$(uci -q get system.@system[0].hostname); lan=$(uci -q get network.lan.ipaddr)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'mode=$(sed -n '\''s/^install_mode=//p'\'' /etc/openwrt-installer-release); scope=$(sed -n '\''s/^rescue_scope=//p'\'' /etc/openwrt-installer-release)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'network=$(sed -n '\''s/^network_source=//p'\'' /etc/openwrt-installer-release); count=$(sed -n '\''s/^rescue_package_count=//p'\'' /etc/openwrt-installer-release)'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'saved=$(wc -l < /etc/owrt-installer/rescued-packages.txt 2>/dev/null | tr -d " "); stale=present; if [ ! -e /etc/owrt-installer/stale-source ] && [ ! -e /etc/uci-defaults/98-installer-network ] && ! grep -q stale-source /etc/openwrt-installer-release; then stale=absent; fi'
		sleep 1
		printf 'expected_scope=%s\r' "$expected_scope"
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'printf "OWRT_RESCUE hostname=%s lan=%s mode=%s scope=%s network=%s packages=%s saved=%s stale=%s\n" "$hostname" "$lan" "$mode" "$scope" "$network" "$count" "$saved" "$stale"'
		sleep 1
		# shellcheck disable=SC2016
		printf '%s\r' 'if [ "$hostname" = rescue-source-qemu ] && [ "$lan" = 10.66.77.1 ] && [ "$mode" = rescue ] && [ "$scope" = "$expected_scope" ] && [ "$network" = imported ] && [ "$count" -gt 0 ] && [ "$saved" = "$count" ] && [ "$stale" = absent ]; then echo OWRT_RESCUE_""OK=1; fi'
	} | nc -N -U "$serial_socket" >/dev/null 2>&1 || die "Could not query rescued system"
	wait_for_log_marker "$serial_log" "OWRT_RESCUE_OK=1" "$boot_pid" "$QEMU_INSTALL_WAIT"
	hmp_command "$monitor_socket" quit
	wait "$boot_pid" || true
	assert_log_contains "$serial_log" "OWRT_RESCUE hostname=rescue-source-qemu"
	assert_log_contains "$serial_log" "lan=10.66.77.1 mode=rescue scope=$expected_scope network=imported"
	assert_log_contains "$serial_log" "stale=absent"
}

run_standard_upgrade_handoff_smoke() {
	target_disk="$1"
	reference_disk="$SMOKE_DIR/target-upgrade-handoff-reference.qcow2"
	serial_log="$SMOKE_DIR/upgrade-handoff-iso.log"
	qemu_log="$SMOKE_DIR/upgrade-handoff-qemu.log"
	monitor_socket="$SMOKE_DIR/upgrade-handoff-monitor.sock"
	rm -f "$reference_disk" "$serial_log" "$qemu_log" "$monitor_socket"
	cp "$target_disk" "$reference_disk"

	log "Starting zero-write standard-upgrade handoff smoke test"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$qemu_log" \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none -vga std -serial "file:$serial_log" \
		-monitor "unix:$monitor_socket,server=on,wait=off" \
		-kernel "$ISO_STAGED_KERNEL" -initrd "$ISO_STAGED_INITRAMFS" \
		-append "console=tty1 console=ttyS0,115200n8 rdinit=/init owrt.mouse=1 owrt.hardware-test=1" \
		-drive "file=$target_disk,format=qcow2,if=virtio" \
		-nic user,model=e1000 -nic user,model=e1000
	handoff_pid="$QEMU_STARTED_PID"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk" "$handoff_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=existing-system-action" "$handoff_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" down down ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=existing-upgrade" "$handoff_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	sleep 2
	hmp_send_keys "$monitor_socket" ret
	sleep 2
	hmp_command "$monitor_socket" quit
	wait "$handoff_pid" || true

	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		env $QEMU_ENV_PREFIX "$QEMU_IMG" compare -f qcow2 -F qcow2 "$reference_disk" "$target_disk" >/dev/null ||
			die "Standard-upgrade handoff modified target disk data"
	else
		"$QEMU_IMG" compare -f qcow2 -F qcow2 "$reference_disk" "$target_disk" >/dev/null ||
			die "Standard-upgrade handoff modified target disk data"
	fi
	assert_log_not_contains "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS="
	log "Zero-write standard-upgrade handoff smoke passed"
}

run_rescue_smoke() {
	target_disk="$(prepare_local_boot_disk rescue)"
	resize_qcow2 "$target_disk" 6G
	find_ovmf
	vars_copy="$SMOKE_DIR/OVMF_VARS_4M-rescue.fd"
	baseline_serial_log="$SMOKE_DIR/rescue-baseline-boot.log"
	baseline_qemu_log="$SMOKE_DIR/rescue-baseline-boot-qemu.log"
	baseline_serial_socket="$SMOKE_DIR/rescue-baseline-serial.sock"
	baseline_monitor_socket="$SMOKE_DIR/rescue-baseline-monitor.sock"
	serial_log="$SMOKE_DIR/rescue-iso.log"
	qemu_log="$SMOKE_DIR/rescue-qemu.log"
	monitor_socket="$SMOKE_DIR/rescue-monitor.sock"
	rm -f "$vars_copy" "$baseline_serial_log" "$baseline_qemu_log" \
		"$baseline_serial_socket" "$baseline_monitor_socket" "$serial_log" \
		"$qemu_log" "$monitor_socket"
	cp "$QEMU_OVMF_VARS" "$vars_copy"

	log "Booting baseline OpenWrt and creating rescue evidence"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$baseline_qemu_log" \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none \
		-chardev "socket,id=serial0,path=$baseline_serial_socket,server=on,wait=off,logfile=$baseline_serial_log" \
		-serial chardev:serial0 -monitor "unix:$baseline_monitor_socket,server=on,wait=off" \
		-drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$vars_copy" \
		-drive "file=$target_disk,format=qcow2,if=virtio" -boot c \
		-nic user,model=e1000 -nic user,model=e1000
	baseline_pid="$QEMU_STARTED_PID"
	wait_for_log_marker "$baseline_serial_log" "Please press Enter to activate this console." "$baseline_pid" "$QEMU_INSTALL_WAIT"
	{
		printf '\r'
		sleep 1
		printf '%s\r' 'uci set system.@system[0].hostname="rescue-source-qemu"; uci commit system'
		sleep 1
		printf '%s\r' 'uci set network.lan.ipaddr="10.66.77.1"; uci commit network'
		sleep 1
		printf '%s\r' 'mkdir -p /etc/owrt-installer /etc/uci-defaults; echo stale-source > /etc/owrt-installer/stale-source; echo stale-source > /etc/openwrt-installer-release'
		sleep 1
		printf '%s\r' 'printf "#!/bin/sh\nexit 77\n" > /etc/uci-defaults/98-installer-network; chmod 755 /etc/uci-defaults/98-installer-network'
		sleep 1
		printf '%s\r' 'sync; echo OWRT_RESCUE_SOURCE_READY=1; poweroff'
	} | nc -N -U "$baseline_serial_socket" >/dev/null 2>&1 || die "Could not prepare rescue baseline"
	wait_for_log_marker "$baseline_serial_log" "OWRT_RESCUE_SOURCE_READY=1" "$baseline_pid" "$QEMU_INSTALL_WAIT"
	wait "$baseline_pid" || true

	log "Starting RAM rescue, bounded reinstall, and restore smoke test"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$qemu_log" \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none -vga std -serial "file:$serial_log" \
		-monitor "unix:$monitor_socket,server=on,wait=off" \
		-kernel "$ISO_STAGED_KERNEL" -initrd "$ISO_STAGED_INITRAMFS" \
		-append "console=tty1 console=ttyS0,115200n8 rdinit=/init owrt.mouse=1" \
		-drive "file=$target_disk,format=qcow2,if=virtio" \
		-nic user,model=e1000 -nic user,model=e1000
	install_pid="$QEMU_STARTED_PID"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=existing-system-action" "$install_pid" "$QEMU_INSTALL_WAIT"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_EXISTING_RESCUE=ready"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=rescue-scope" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" down ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=rescue-full-warning" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=config-import-network" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=rescue-ready" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-profile" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" down ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-layout" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-warning" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=review-summary" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=review-action" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=final-erase-info" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=exact-erase" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" shift-e shift-r shift-a shift-s shift-e spc slash d e v slash v d a ret
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS=100" "$install_pid" "$QEMU_INSTALL_WAIT"
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_ROOTFS_VERIFIED_MIB=" "$install_pid" "$QEMU_INSTALL_WAIT"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=installation-success" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=post-install-menu" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" down down ret
	sleep 2
	hmp_command "$monitor_socket" quit
	wait "$install_pid" || true

	assert_log_contains "$serial_log" "OWRT_INSTALLER_RESCUE_READY=$OPENWRT_VERSION:full"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_STORAGE_LAYOUT=bounded"
	assert_log_not_contains "$serial_log" "Installation failed"
	verify_installed_geometry bounded "$target_disk" "$vars_copy" 8388608 1 rescue expanded 0
	verify_rescued_system "$target_disk" "$vars_copy" full
	run_standard_upgrade_handoff_smoke "$target_disk"
	log "Existing OpenWrt RAM rescue, restore, reboot, and handoff smoke passed"
}

prepare_config_import_usb() {
	fixture_dir="$SMOKE_DIR/config-import-fixture"
	CONFIG_IMPORT_USB_IMAGE="$SMOKE_DIR/config-import-usb.img"
	CONFIG_IMPORT_BACKUP="$fixture_dir/router-backup.tar.gz"
	CONFIG_IMPORT_MKFS_FAT="$IMAGEBUILDER_DIR/staging_dir/host/bin/mkfs.fat"
	CONFIG_IMPORT_MMD="$IMAGEBUILDER_DIR/staging_dir/host/bin/mmd"
	CONFIG_IMPORT_MCOPY="$IMAGEBUILDER_DIR/staging_dir/host/bin/mcopy"

	[ -x "$CONFIG_IMPORT_MKFS_FAT" ] || die "ImageBuilder mkfs.fat is required for config-import QEMU smoke"
	[ -x "$CONFIG_IMPORT_MMD" ] || die "ImageBuilder mmd is required for config-import QEMU smoke"
	[ -x "$CONFIG_IMPORT_MCOPY" ] || die "ImageBuilder mcopy is required for config-import QEMU smoke"
	rm -rf "$fixture_dir"
	rm -f "$CONFIG_IMPORT_USB_IMAGE"
	mkdir -p "$fixture_dir/root/etc/config" "$fixture_dir/root/etc/owrt-installer" \
		"$fixture_dir/root/etc/uci-defaults"
	cat > "$fixture_dir/root/etc/config/system" <<'EOF'
config system 'system'
	option hostname 'imported-qemu'
	option timezone 'UTC'
EOF
	cat > "$fixture_dir/root/etc/config/network" <<'EOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config device
	option name 'br-imported'
	option type 'bridge'
	list ports 'eth0'

config interface 'lan'
	option device 'br-imported'
	option proto 'static'
	option ipaddr '10.123.45.1'
	option netmask '255.255.255.0'

config interface 'wan'
	option device 'eth1'
	option proto 'dhcp'
EOF
	printf '%s\n' 'LAN_MAC=stale-qemu' > "$fixture_dir/root/etc/owrt-installer/interface-map"
	printf '%s\n' '#!/bin/sh' 'exit 77' > "$fixture_dir/root/etc/uci-defaults/98-installer-network"
	chmod 0755 "$fixture_dir/root/etc/uci-defaults/98-installer-network"
	printf '%s\n' 'installed_by=stale-qemu' > "$fixture_dir/root/etc/openwrt-installer-release"
	tar -czf "$CONFIG_IMPORT_BACKUP" -C "$fixture_dir/root" etc
	CONFIG_IMPORT_BACKUP_SHA256="$(sha256sum "$CONFIG_IMPORT_BACKUP" | awk '{ print $1 }')"

	truncate -s 16M "$CONFIG_IMPORT_USB_IMAGE"
	"$CONFIG_IMPORT_MKFS_FAT" -n OWRTBACKUP "$CONFIG_IMPORT_USB_IMAGE" >/dev/null
	"$CONFIG_IMPORT_MMD" -i "$CONFIG_IMPORT_USB_IMAGE" ::/backups
	"$CONFIG_IMPORT_MCOPY" -i "$CONFIG_IMPORT_USB_IMAGE" "$CONFIG_IMPORT_BACKUP" \
		::/backups/router-backup.tar.gz
}

run_config_import_smoke() {
	serial_log="$SMOKE_DIR/config-import-iso.log"
	qemu_log="$SMOKE_DIR/config-import-qemu.log"
	monitor_socket="$SMOKE_DIR/config-import-monitor.sock"
	target_disk="$SMOKE_DIR/target-config-import.qcow2"
	boot_serial_log="$SMOKE_DIR/config-import-installed-boot.log"
	boot_qemu_log="$SMOKE_DIR/config-import-installed-boot-qemu.log"
	boot_serial_socket="$SMOKE_DIR/config-import-installed-serial.sock"
	boot_monitor_socket="$SMOKE_DIR/config-import-installed-monitor.sock"

	prepare_config_import_usb
	rm -f "$target_disk" "$serial_log" "$qemu_log" "$monitor_socket" \
		"$boot_serial_log" "$boot_qemu_log" "$boot_serial_socket" \
		"$boot_monitor_socket"
	ensure_qcow2 "$target_disk"

	log "Starting USB configuration import/install smoke test"
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_INSTALL_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" -L "$QEMU_L_ARG" \
			-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
			-display none -vga std -serial "file:$serial_log" \
			-monitor "unix:$monitor_socket,server=on,wait=off" \
			-cdrom "$ISO_IMAGE" -boot d \
			-drive "file=$target_disk,format=qcow2,if=virtio" \
			-device qemu-xhci,id=config_xhci \
			-drive "file=$CONFIG_IMPORT_USB_IMAGE,format=raw,if=none,readonly=on,id=config_backup" \
			-nic user,model=e1000 -nic user,model=e1000 > "$qemu_log" 2>&1 &
	else
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_INSTALL_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" \
			-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
			-display none -vga std -serial "file:$serial_log" \
			-monitor "unix:$monitor_socket,server=on,wait=off" \
			-cdrom "$ISO_IMAGE" -boot d \
			-drive "file=$target_disk,format=qcow2,if=virtio" \
			-device qemu-xhci,id=config_xhci \
			-drive "file=$CONFIG_IMPORT_USB_IMAGE,format=raw,if=none,readonly=on,id=config_backup" \
			-nic user,model=e1000 -nic user,model=e1000 > "$qemu_log" 2>&1 &
	fi
	install_pid=$!

	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=install-type" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_command "$monitor_socket" "device_add usb-storage,drive=config_backup,id=config_usb"
	sleep 3
	hmp_send_keys "$monitor_socket" down ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=config-import-archive" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=config-import-scope" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=config-import-network" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=config-import-ready" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-profile" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=review-summary" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=review-action" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=final-erase-info" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=exact-erase" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" shift-e shift-r shift-a shift-s shift-e spc slash d e v slash v d a ret

	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS=100" "$install_pid" "$QEMU_INSTALL_WAIT"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=installation-success" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=post-install-menu" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" down down ret
	sleep 2
	hmp_command "$monitor_socket" quit
	wait "$install_pid" || true

	assert_log_not_contains "$serial_log" "Installation failed"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS=100"

	log "Booting the disk installed with imported configuration"
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
	{
		printf '\r'
		sleep 1
		printf 'printf "OWRT_CONFIG_IMPORT_ROOT_MODE="; ls -ld /; printf "OWRT_CONFIG_IMPORT_ETC_MODE="; ls -ld /etc; cat /etc/config/system; cat /etc/config/network; cat /etc/openwrt-installer-release; if [ ! -e /etc/owrt-installer/interface-map ] && [ ! -e /etc/uci-defaults/98-installer-network ]; then echo OWRT_CONFIG_IMPORT_STALE_STATE_""ABSENT=1; fi\r'
	} | nc -N -U "$boot_serial_socket" >/dev/null 2>&1 ||
		die "Could not query config-import installed system console"
	wait_for_log_marker "$boot_serial_log" "OWRT_CONFIG_IMPORT_STALE_STATE_ABSENT=1" "$boot_pid" "$QEMU_INSTALL_WAIT"
	hmp_command "$boot_monitor_socket" quit
	wait "$boot_pid" || true

	assert_log_contains "$boot_serial_log" "option hostname 'imported-qemu'"
	assert_log_contains "$boot_serial_log" "OWRT_CONFIG_IMPORT_ROOT_MODE=drwxr-xr-x"
	assert_log_contains "$boot_serial_log" "OWRT_CONFIG_IMPORT_ETC_MODE=drwxr-xr-x"
	assert_log_contains "$boot_serial_log" "option name 'br-imported'"
	assert_log_contains "$boot_serial_log" "option ipaddr '10.123.45.1'"
	assert_log_contains "$boot_serial_log" "install_mode=import"
	assert_log_contains "$boot_serial_log" "network_source=imported"
	assert_log_contains "$boot_serial_log" "config_import_policy=config-only"
	assert_log_contains "$boot_serial_log" "config_import_sha256=$CONFIG_IMPORT_BACKUP_SHA256"
	assert_log_contains "$boot_serial_log" "lan_ip=imported"
	assert_log_contains "$boot_serial_log" "wan_proto=imported"
	assert_log_contains "$boot_serial_log" "target_disk=/dev/vda"
	log "USB configuration import/install/boot smoke passed"
}

run_online_install_smoke() {
	online_mode="$1"
	case "$online_mode" in
		bios)
			online_image_type="ext4-combined"
			online_boot_label="BIOS"
			online_storage_layout="image"
			;;
		uefi)
			online_image_type="ext4-combined-efi"
			online_boot_label="UEFI"
			online_storage_layout="image"
			;;
		*) die "Unsupported QEMU online install mode: $online_mode" ;;
	esac
	case "$QEMU_ONLINE_WAIT" in
		''|*[!0-9]*) die "QEMU_ONLINE_WAIT must be an integer number of seconds" ;;
	esac

	serial_log="$SMOKE_DIR/online-$online_mode-iso.log"
	qemu_log="$SMOKE_DIR/online-$online_mode-qemu.log"
	monitor_socket="$SMOKE_DIR/online-$online_mode-monitor.sock"
	target_disk="$SMOKE_DIR/target-online-$online_mode.qcow2"
	boot_serial_log="$SMOKE_DIR/online-$online_mode-installed-boot.log"
	boot_qemu_log="$SMOKE_DIR/online-$online_mode-installed-boot-qemu.log"
	boot_serial_socket="$SMOKE_DIR/online-$online_mode-installed-serial.sock"
	boot_monitor_socket="$SMOKE_DIR/online-$online_mode-installed-monitor.sock"
	vars_copy="$SMOKE_DIR/OVMF_VARS_4M-online-$online_mode.fd"

	rm -f "$target_disk" "$serial_log" "$qemu_log" "$monitor_socket" \
		"$boot_serial_log" "$boot_qemu_log" "$boot_serial_socket" \
		"$boot_monitor_socket" "$vars_copy"
	if [ "$online_mode" = "bios" ]; then
		create_qcow2 "$target_disk" 6G
	else
		ensure_qcow2 "$target_disk"
	fi

	set -- \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none -vga std -serial "file:$serial_log" \
		-monitor "unix:$monitor_socket,server=on,wait=off"
	if [ "$online_mode" = "uefi" ]; then
		online_ovmf_code="${OVMF_CODE:-$(find_first_file \
			"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_CODE_4M.fd" \
			"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_CODE.fd" \
			/usr/share/OVMF/OVMF_CODE_4M.fd \
			/usr/share/OVMF/OVMF_CODE.fd \
			/usr/share/edk2/x64/OVMF_CODE.fd \
			/usr/share/qemu/OVMF_CODE.fd || true)}"
		online_ovmf_vars="${OVMF_VARS:-$(find_first_file \
			"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_VARS_4M.fd" \
			"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_VARS.fd" \
			/usr/share/OVMF/OVMF_VARS_4M.fd \
			/usr/share/OVMF/OVMF_VARS.fd \
			/usr/share/edk2/x64/OVMF_VARS.fd \
			/usr/share/qemu/OVMF_VARS.fd || true)}"
		[ -f "$online_ovmf_code" ] || die "OVMF_CODE.fd not found for online UEFI smoke"
		[ -f "$online_ovmf_vars" ] || die "OVMF_VARS.fd not found for online UEFI smoke"
		cp "$online_ovmf_vars" "$vars_copy"
		set -- "$@" \
			-drive "if=pflash,format=raw,readonly=on,file=$online_ovmf_code" \
			-drive "if=pflash,format=raw,file=$vars_copy"
	fi
	set -- "$@" \
		-kernel "$ISO_STAGED_KERNEL" -initrd "$ISO_STAGED_INITRAMFS" \
		-append "console=tty1 console=ttyS0,115200n8 rdinit=/init owrt.netinstall=1" \
		-drive "file=$target_disk,format=qcow2,if=none,id=local_target" \
		-device "virtio-blk-pci,drive=local_target,bootindex=2" \
		-boot "menu=off,strict=on" \
		-nic user,model=e1000 -nic user,model=e1000

	log "Starting $online_boot_label online download/install smoke test"
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_ONLINE_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" -L "$QEMU_L_ARG" "$@" \
			> "$qemu_log" 2>&1 &
	else
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_ONLINE_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" "$@" \
			> "$qemu_log" 2>&1 &
	fi
	install_pid=$!

	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_NETINSTALL=active" "$install_pid" "$QEMU_ONLINE_WAIT"
	[ -S "$monitor_socket" ] || die "QEMU online monitor socket was not created"
	wait_for_either_log_marker "$serial_log" \
		"OWRT_INSTALLER_UI_READY=online-unavailable" \
		"OWRT_INSTALLER_UI_READY=online-ready" \
		"$install_pid" "$QEMU_ONLINE_WAIT"
	sleep "$QEMU_UI_SETTLE"
	if [ "$WAITED_LOG_MARKER" = "OWRT_INSTALLER_UI_READY=online-unavailable" ]; then
		hmp_send_keys "$monitor_socket" ret
		wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=online-uplink" "$install_pid" "$QEMU_ONLINE_WAIT"
		hmp_send_keys "$monitor_socket" ret
		wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=online-network-mode" "$install_pid" "$QEMU_ONLINE_WAIT"
		hmp_send_keys "$monitor_socket" ret
		wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=online-ready" "$install_pid" "$QEMU_ONLINE_WAIT"
	fi
	assert_log_contains "$serial_log" "OWRT_INSTALLER_NETINSTALL_SIGNATURE_VERIFIED=1"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_NETINSTALL_PAYLOAD_VERIFIED=1"
	online_version="$(sed -n 's/.*OWRT_INSTALLER_NETINSTALL_VERSION=\([^[:space:]]*\).*/\1/p' "$serial_log" |
		tail -n 1 | tr -d '\r')"
	printf '%s\n' "$online_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
		die "QEMU online smoke did not report a stable OpenWrt version"
	hmp_send_keys "$monitor_socket" ret

	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=install-type" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-profile" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=lan-interface" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=wan-interface-auto" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=lan-ip" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=wan-mode" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=wan6-mode" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=review-summary" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=review-action" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=final-erase-info" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=exact-erase" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" shift-e shift-r shift-a shift-s shift-e spc slash d e v slash v d a ret

	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS=100" "$install_pid" "$QEMU_ONLINE_WAIT"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=installation-success" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=post-install-menu" "$install_pid" "$QEMU_ONLINE_WAIT"
	hmp_send_keys "$monitor_socket" ret
	sleep 2
	hmp_command "$monitor_socket" quit
	wait "$install_pid" || true

	assert_log_not_contains "$serial_log" "Installation failed"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS=100"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_NETINSTALL_IMAGE=openwrt-$online_version-x86-64-generic-$online_image_type.img.gz"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_STORAGE_LAYOUT=$online_storage_layout"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_STORAGE_PROFILE=compatible"

	set -- \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none \
		-chardev "socket,id=serial0,path=$boot_serial_socket,server=on,wait=off,logfile=$boot_serial_log" \
		-serial chardev:serial0 \
		-monitor "unix:$boot_monitor_socket,server=on,wait=off"
	if [ "$online_mode" = "uefi" ]; then
		set -- "$@" \
			-drive "if=pflash,format=raw,readonly=on,file=$online_ovmf_code" \
			-drive "if=pflash,format=raw,file=$vars_copy"
	fi
	set -- "$@" \
		-drive "file=$target_disk,format=qcow2,if=virtio" -boot c \
		-nic user,model=e1000 -nic user,model=e1000

	log "Booting the $online_boot_label disk downloaded and written by the installer"
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_ONLINE_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" -L "$QEMU_L_ARG" "$@" \
			> "$boot_qemu_log" 2>&1 &
	else
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_ONLINE_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" "$@" \
			> "$boot_qemu_log" 2>&1 &
	fi
	boot_pid=$!
	wait_for_log_marker "$boot_serial_log" "Please press Enter to activate this console." "$boot_pid" "$QEMU_ONLINE_WAIT"
	{ printf '\r'; sleep 1; printf 'cat /etc/openwrt-installer-release\r'; } |
		nc -N -U "$boot_serial_socket" >/dev/null 2>&1 ||
		die "Could not query the online-installed system console"
	wait_for_log_marker "$boot_serial_log" "payload_source=downloaded-official" "$boot_pid" "$QEMU_ONLINE_WAIT"
	hmp_command "$boot_monitor_socket" quit
	wait "$boot_pid" || true
	assert_log_contains "$boot_serial_log" "openwrt_version=$online_version"
	assert_log_contains "$boot_serial_log" "image_type=$online_image_type"
	assert_log_contains "$boot_serial_log" "boot_mode=$online_boot_label"
	assert_log_contains "$boot_serial_log" "target_disk=/dev/vda"
	assert_log_contains "$boot_serial_log" "storage_layout=$online_storage_layout"
	if [ "$online_storage_layout" = "bounded" ]; then
		assert_log_contains "$boot_serial_log" "rootfs_target_mib=4096"
	fi
	log "$online_boot_label online download/install/boot smoke passed with OpenWrt $online_version"
}

prepare_local_boot_disk() {
	local_mode="$1"
	local_raw="$SMOKE_DIR/target-local-disk-$local_mode.raw"
	local_disk="$SMOKE_DIR/target-local-disk-$local_mode.qcow2"

	rm -f "$local_raw" "$local_disk"
	gzip -dc "$TARGET_IMAGE" > "$local_raw" ||
		die "Could not decompress target image for local-disk $local_mode smoke"
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		env $QEMU_ENV_PREFIX "$QEMU_IMG" convert -f raw -O qcow2 "$local_raw" "$local_disk" ||
			die "Could not create local-disk $local_mode qcow2"
	else
		"$QEMU_IMG" convert -f raw -O qcow2 "$local_raw" "$local_disk" ||
			die "Could not create local-disk $local_mode qcow2"
	fi
	rm -f "$local_raw"
	printf '%s\n' "$local_disk"
}

run_local_disk_boot_smoke() {
	local_mode="$1"
	case "$local_mode" in
		bios) local_boot_label="BIOS" ;;
		uefi) local_boot_label="UEFI" ;;
		*) die "Unsupported local-disk boot mode: $local_mode" ;;
	esac

	serial_log="$SMOKE_DIR/local-disk-$local_mode-iso.log"
	qemu_log="$SMOKE_DIR/local-disk-$local_mode-qemu.log"
	serial_socket="$SMOKE_DIR/local-disk-$local_mode-serial.sock"
	monitor_socket="$SMOKE_DIR/local-disk-$local_mode-monitor.sock"
	vars_copy="$SMOKE_DIR/OVMF_VARS_4M-local-disk-$local_mode.fd"
	target_disk="$(prepare_local_boot_disk "$local_mode")"
	rm -f "$serial_log" "$qemu_log" "$serial_socket" "$monitor_socket" "$vars_copy"

	set -- \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none \
		-chardev "socket,id=serial0,path=$serial_socket,server=on,wait=off,logfile=$serial_log" \
		-serial chardev:serial0 \
		-monitor "unix:$monitor_socket,server=on,wait=off"
	if [ "$local_mode" = "uefi" ]; then
		local_ovmf_code="${OVMF_CODE:-$(find_first_file \
			"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_CODE_4M.fd" \
			"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_CODE.fd" \
			/usr/share/OVMF/OVMF_CODE_4M.fd \
			/usr/share/OVMF/OVMF_CODE.fd \
			/usr/share/edk2/x64/OVMF_CODE.fd \
			/usr/share/qemu/OVMF_CODE.fd || true)}"
		local_ovmf_vars="${OVMF_VARS:-$(find_first_file \
			"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_VARS_4M.fd" \
			"$LOCAL_QEMU_ROOT/usr/share/OVMF/OVMF_VARS.fd" \
			/usr/share/OVMF/OVMF_VARS_4M.fd \
			/usr/share/OVMF/OVMF_VARS.fd \
			/usr/share/edk2/x64/OVMF_VARS.fd \
			/usr/share/qemu/OVMF_VARS.fd || true)}"
		[ -f "$local_ovmf_code" ] || die "OVMF_CODE.fd not found for local-disk UEFI smoke"
		[ -f "$local_ovmf_vars" ] || die "OVMF_VARS.fd not found for local-disk UEFI smoke"
		cp "$local_ovmf_vars" "$vars_copy"
		set -- "$@" \
			-drive "if=pflash,format=raw,readonly=on,file=$local_ovmf_code" \
			-drive "if=pflash,format=raw,file=$vars_copy"
	fi
	set -- "$@" \
		-cdrom "$ISO_IMAGE" \
		-drive "file=$target_disk,format=qcow2,if=virtio" \
		-boot "once=d,menu=off" \
		-nic user,model=e1000 -nic user,model=e1000

	log "Starting $local_boot_label installed OpenWrt boot-through-ISO smoke test"
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_INSTALL_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" -L "$QEMU_L_ARG" "$@" \
			> "$qemu_log" 2>&1 &
	else
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_INSTALL_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" "$@" \
			> "$qemu_log" 2>&1 &
	fi
	boot_pid=$!

	wait_for_log_marker "$serial_log" "Boot installed OpenWrt from local disk" "$boot_pid" 45
	[ -S "$monitor_socket" ] || die "QEMU local-disk monitor socket was not created"
	hmp_send_keys "$monitor_socket" ret
	wait_for_log_marker "$serial_log" "Please press Enter to activate this console." "$boot_pid" "$QEMU_INSTALL_WAIT"
	{ printf '\r'; sleep 1; printf 'cat /etc/openwrt_release\r'; } |
		nc -N -U "$serial_socket" >/dev/null 2>&1 ||
		die "Could not query local-disk OpenWrt console"
	wait_for_log_marker "$serial_log" "DISTRIB_RELEASE='$OPENWRT_VERSION'" "$boot_pid" "$QEMU_INSTALL_WAIT"
	hmp_command "$monitor_socket" quit
	wait "$boot_pid" || true
	assert_log_not_contains "$serial_log" "No installed OpenWrt boot partition"
	log "$local_boot_label installed OpenWrt boot-through-ISO smoke passed"
}

run_local_disk_missing_smoke() {
	serial_log="$SMOKE_DIR/local-disk-missing-iso.log"
	qemu_log="$SMOKE_DIR/local-disk-missing-qemu.log"
	monitor_socket="$SMOKE_DIR/local-disk-missing-monitor.sock"
	target_disk="$SMOKE_DIR/target-local-disk-missing.qcow2"

	rm -f "$serial_log" "$qemu_log" "$monitor_socket" "$target_disk"
	ensure_qcow2 "$target_disk"
	log "Starting missing local OpenWrt disk menu smoke test"
	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" -L "$QEMU_L_ARG" \
			-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
			-display none -serial "file:$serial_log" \
			-monitor "unix:$monitor_socket,server=on,wait=off" \
			-cdrom "$ISO_IMAGE" -boot d \
			-drive "file=$target_disk,format=qcow2,if=virtio" > "$qemu_log" 2>&1 &
	else
		# shellcheck disable=SC2086 # QEMU_ENV_PREFIX is controlled key=value pairs.
		timeout "$QEMU_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" \
			-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
			-display none -serial "file:$serial_log" \
			-monitor "unix:$monitor_socket,server=on,wait=off" \
			-cdrom "$ISO_IMAGE" -boot d \
			-drive "file=$target_disk,format=qcow2,if=virtio" > "$qemu_log" 2>&1 &
	fi
	boot_pid=$!
	wait_for_log_marker "$serial_log" "Boot installed OpenWrt from local disk" "$boot_pid" 45
	hmp_send_keys "$monitor_socket" down ret
	wait_for_log_marker "$serial_log" "No installed OpenWrt boot partition with label 'kernel' was found." "$boot_pid" 45
	hmp_command "$monitor_socket" quit
	wait "$boot_pid" || true
	log "Missing local OpenWrt disk menu smoke passed"
}

prepare_custom_build_usb() {
	custom_mode="$1"
	case "$custom_mode" in
		bios)
			custom_image_type="ext4-combined"
			custom_source="$OUTPUT_DIR/openwrt-x86-64-target-bios.img.gz"
			;;
		uefi)
			custom_image_type="ext4-combined-efi"
			custom_source="$OUTPUT_DIR/openwrt-x86-64-target.img.gz"
			;;
		*) die "Unsupported custom-build QEMU mode: $custom_mode" ;;
	esac
	[ -s "$custom_source" ] || die "Custom-build $custom_image_type source image is missing"
	CUSTOM_BUILD_QEMU_USB="$SMOKE_DIR/custom-build-$custom_mode-usb.img"
	CUSTOM_BUILD_QEMU_FILENAME="openwrt-${OPENWRT_VERSION}-x86-64-generic-${custom_image_type}.img.gz"
	CUSTOM_BUILD_QEMU_SHA="$(sha256sum "$custom_source" | awk '{ print $1 }')"
	custom_sidecar="$SMOKE_DIR/$CUSTOM_BUILD_QEMU_FILENAME.sha256"
	printf '%s  %s\n' "$CUSTOM_BUILD_QEMU_SHA" "$CUSTOM_BUILD_QEMU_FILENAME" > "$custom_sidecar"
	rm -f "$CUSTOM_BUILD_QEMU_USB"
	truncate -s 64M "$CUSTOM_BUILD_QEMU_USB"
	"$IMAGEBUILDER_DIR/staging_dir/host/bin/mkfs.fat" -n CUSTOMBUILD \
		"$CUSTOM_BUILD_QEMU_USB" >/dev/null
	"$IMAGEBUILDER_DIR/staging_dir/host/bin/mmd" -i "$CUSTOM_BUILD_QEMU_USB" \
		::/CUSTOM_BUILD
	"$IMAGEBUILDER_DIR/staging_dir/host/bin/mcopy" -i "$CUSTOM_BUILD_QEMU_USB" \
		"$custom_source" "::/CUSTOM_BUILD/$CUSTOM_BUILD_QEMU_FILENAME"
	"$IMAGEBUILDER_DIR/staging_dir/host/bin/mcopy" -i "$CUSTOM_BUILD_QEMU_USB" \
		"$custom_sidecar" "::/CUSTOM_BUILD/$CUSTOM_BUILD_QEMU_FILENAME.sha256"
}

run_custom_build_smoke() {
	custom_mode="$1"
	case "$custom_mode" in
		bios)
			custom_boot_label="BIOS"
			custom_image_type="ext4-combined"
			;;
		uefi)
			custom_boot_label="UEFI"
			custom_image_type="ext4-combined-efi"
			;;
		*) die "Unsupported custom-build QEMU mode: $custom_mode" ;;
	esac
	prepare_custom_build_usb "$custom_mode"
	serial_log="$SMOKE_DIR/custom-build-$custom_mode-iso.log"
	qemu_log="$SMOKE_DIR/custom-build-$custom_mode-qemu.log"
	monitor_socket="$SMOKE_DIR/custom-build-$custom_mode-monitor.sock"
	logo_screenshot="$SMOKE_DIR/custom-build-$custom_mode-logo.ppm"
	target_disk="$SMOKE_DIR/target-custom-build-$custom_mode.qcow2"
	boot_serial_log="$SMOKE_DIR/custom-build-$custom_mode-installed-boot.log"
	boot_qemu_log="$SMOKE_DIR/custom-build-$custom_mode-installed-boot-qemu.log"
	boot_serial_socket="$SMOKE_DIR/custom-build-$custom_mode-installed-serial.sock"
	boot_monitor_socket="$SMOKE_DIR/custom-build-$custom_mode-installed-monitor.sock"
	vars_copy="$SMOKE_DIR/OVMF_VARS_4M-custom-build-$custom_mode.fd"

	rm -f "$target_disk" "$serial_log" "$qemu_log" "$monitor_socket" \
		"$logo_screenshot" "$boot_serial_log" "$boot_qemu_log" \
		"$boot_serial_socket" "$boot_monitor_socket" "$vars_copy"
	create_qcow2 "$target_disk" 6G

	set -- \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none -vga std -serial "file:$serial_log" \
		-monitor "unix:$monitor_socket,server=on,wait=off"
	if [ "$custom_mode" = "uefi" ]; then
		find_ovmf
		cp "$QEMU_OVMF_VARS" "$vars_copy"
		set -- "$@" \
			-drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
			-drive "if=pflash,format=raw,file=$vars_copy"
	fi
	set -- "$@" \
		-cdrom "$ISO_IMAGE" -boot "once=d,menu=off" \
		-drive "file=$target_disk,format=qcow2,if=virtio" \
		-device qemu-xhci,id=custom_xhci \
		-drive "file=$CUSTOM_BUILD_QEMU_USB,format=raw,if=none,readonly=on,id=custom_media" \
		-device usb-storage,drive=custom_media,id=custom_usb \
		-nic user,model=e1000 -nic user,model=e1000

	log "Starting $custom_boot_label CUSTOM_BUILD USB install smoke test"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$qemu_log" "$@"
	install_pid="$QEMU_STARTED_PID"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=image-source" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_command "$monitor_socket" "screendump $logo_screenshot"
	hmp_send_keys "$monitor_socket" down ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=custom-build-select" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=custom-build-warning" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=custom-build-ready" "$install_pid" "$QEMU_INSTALL_WAIT"
	hmp_send_keys "$monitor_socket" ret
	drive_clean_install_flow "$serial_log" "$monitor_socket" "$install_pid" compatible "$QEMU_INSTALL_WAIT" second

	assert_nonblank_ppm "$logo_screenshot"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_CUSTOM_BUILD_IMAGE=$CUSTOM_BUILD_QEMU_FILENAME"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_CUSTOM_BUILD_CHECKSUM=sidecar-verified-unsigned"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_CUSTOM_BUILD_VERIFIED=1"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_WRITE_PROGRESS=100"
	assert_log_not_contains "$serial_log" "Installation failed"

	set -- \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none \
		-chardev "socket,id=serial0,path=$boot_serial_socket,server=on,wait=off,logfile=$boot_serial_log" \
		-serial chardev:serial0 \
		-monitor "unix:$boot_monitor_socket,server=on,wait=off"
	if [ "$custom_mode" = "uefi" ]; then
		# The install boot leaves an explicit virtual-CD entry in OVMF NVRAM.
		# A fresh VARS image models removing installer media and forces the normal
		# fallback scan of the installed disk's EFI/BOOT/BOOTX64.EFI path.
		cp "$QEMU_OVMF_VARS" "$vars_copy"
		set -- "$@" \
			-drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
			-drive "if=pflash,format=raw,file=$vars_copy"
	fi
	set -- "$@" \
		-drive "file=$target_disk,format=qcow2,if=virtio" -boot c \
		-nic user,model=e1000 -nic user,model=e1000
	log "Booting the $custom_boot_label CUSTOM_BUILD installation"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$boot_qemu_log" "$@"
	boot_pid="$QEMU_STARTED_PID"
	wait_for_log_marker "$boot_serial_log" "Please press Enter to activate this console." "$boot_pid" "$QEMU_INSTALL_WAIT"
	{ printf '\r'; sleep 1; printf 'cat /etc/openwrt-installer-release\r'; } |
		nc -N -U "$boot_serial_socket" >/dev/null 2>&1 ||
		die "Could not query the custom-build installed system console"
	wait_for_log_marker "$boot_serial_log" "payload_source=custom-build" "$boot_pid" "$QEMU_INSTALL_WAIT"
	hmp_command "$boot_monitor_socket" quit
	wait "$boot_pid" || true
	assert_log_contains "$boot_serial_log" "openwrt_version=custom-$OPENWRT_VERSION"
	assert_log_contains "$boot_serial_log" "payload_filename=$CUSTOM_BUILD_QEMU_FILENAME"
	assert_log_contains "$boot_serial_log" "payload_checksum_status=sidecar-verified-unsigned"
	assert_log_contains "$boot_serial_log" "image_type=$custom_image_type"
	assert_log_contains "$boot_serial_log" "boot_mode=$custom_boot_label"
	assert_log_contains "$boot_serial_log" "target_disk=/dev/vda"
	log "$custom_boot_label CUSTOM_BUILD USB install/boot smoke passed"
}

serial_send_line() {
	serial_socket="$1"
	serial_text="$2"
	{ printf '%s\r' "$serial_text"; sleep 0.2; } |
		nc -N -U "$serial_socket" >/dev/null 2>&1 ||
		die "Could not send input to the serial installer"
}

run_serial_console_smoke() {
	serial_log="$SMOKE_DIR/serial-console.log"
	qemu_log="$SMOKE_DIR/serial-console-qemu.log"
	serial_socket="$SMOKE_DIR/serial-console.sock"
	monitor_socket="$SMOKE_DIR/serial-console-monitor.sock"
	target_disk="$SMOKE_DIR/serial-console-target.raw"
	rm -f "$serial_log" "$qemu_log" "$serial_socket" "$monitor_socket" "$target_disk"
	truncate -s 1G "$target_disk"
	serial_before_hash="$(sha256sum "$target_disk" | awk '{ print $1 }')"

	set -- \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none -vga none \
		-kernel "$ISO_STAGED_KERNEL" -initrd "$ISO_STAGED_INITRAMFS" \
		-append "console=tty1 console=ttyS0,115200n8 rdinit=/init owrt.console=dual owrt.hardware-test=1" \
		-chardev "socket,id=serial0,path=$serial_socket,server=on,wait=off,logfile=$serial_log" \
		-serial chardev:serial0 \
		-monitor "unix:$monitor_socket,server=on,wait=off" \
		-drive "file=$target_disk,format=raw,if=virtio" \
		-nic user,model=e1000 -nic user,model=e1000
	log "Starting headless dual-console arbitration and serial dry-run smoke test"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$qemu_log" "$@"
	serial_pid="$QEMU_STARTED_PID"
	wait_for_log_marker "$serial_log" "Press Enter or type INSTALL to run the installer on ttyS0." \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	serial_send_line "$serial_socket" ""
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_BROKER_OWNER=ttyS0" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_FRAMEBUFFER=text" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	serial_send_line "$serial_socket" 1
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=install-type" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	serial_send_line "$serial_socket" 1
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=storage-profile" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	serial_send_line "$serial_socket" 1
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=lan-interface" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	serial_send_line "$serial_socket" 1
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=lan-ip" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	serial_send_line "$serial_socket" ""
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=wan-mode" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	serial_send_line "$serial_socket" 1
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=wan6-mode" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	serial_send_line "$serial_socket" 1
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=review-action" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	serial_send_line "$serial_socket" 1
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_UI_READY=exact-erase" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	serial_send_line "$serial_socket" "ERASE /dev/vda"
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_DRY_RUN_COMPLETE=1" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_BROKER_FINISHED=ttyS0:0" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	hmp_command "$monitor_socket" quit
	wait "$serial_pid" || true
	serial_after_hash="$(sha256sum "$target_disk" | awk '{ print $1 }')"
	[ "$serial_before_hash" = "$serial_after_hash" ] ||
		die "Serial hardware dry-run changed the target disk"
	[ "$(grep -F -c 'OWRT_INSTALLER_BROKER_OWNER=' "$serial_log")" -eq 1 ] ||
		die "Serial arbitration emitted more than one owner"
	assert_log_contains "$serial_log" "OWRT_INSTALLER_UI_BACKEND=line"
	assert_log_not_contains "$serial_log" "OWRT_INSTALLER_UI_BACKEND=whiptail"
	assert_log_not_contains "$serial_log" "Installation failed"
	log "Headless serial ownership, line wizard, and disk immutability passed"
}

run_serial_grub_smoke() {
	serial_log="$SMOKE_DIR/serial-grub.log"
	qemu_log="$SMOKE_DIR/serial-grub-qemu.log"
	serial_socket="$SMOKE_DIR/serial-grub.sock"
	monitor_socket="$SMOKE_DIR/serial-grub-monitor.sock"
	target_disk="$SMOKE_DIR/serial-grub-target.raw"
	rm -f "$serial_log" "$qemu_log" "$serial_socket" "$monitor_socket" "$target_disk"
	truncate -s 1G "$target_disk"
	serial_before_hash="$(sha256sum "$target_disk" | awk '{ print $1 }')"
	set -- \
		-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
		-display none -vga std \
		-chardev "socket,id=serial0,path=$serial_socket,server=on,wait=off,logfile=$serial_log" \
		-serial chardev:serial0 \
		-monitor "unix:$monitor_socket,server=on,wait=off" \
		-cdrom "$ISO_IMAGE" -boot d \
		-drive "file=$target_disk,format=raw,if=virtio" \
		-nic user,model=e1000 -nic user,model=e1000
	log "Starting forced serial GRUB-entry smoke test"
	start_qemu_background "$QEMU_INSTALL_TIMEOUT" "$qemu_log" "$@"
	serial_pid="$QEMU_STARTED_PID"
	wait_for_log_marker "$serial_log" "OpenWrt x86 Installer (serial 115200 8N1)" \
		"$serial_pid" 60
	hmp_send_keys "$monitor_socket" down down ret
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_BROKER_OWNER=ttyS0" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_FRAMEBUFFER=" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	wait_for_log_marker "$serial_log" "OWRT_INSTALLER_UI_BACKEND=line" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=target-disk" \
		"$serial_pid" "$QEMU_HARDWARE_WAIT"
	hmp_command "$monitor_socket" quit
	wait "$serial_pid" || true
	serial_after_hash="$(sha256sum "$target_disk" | awk '{ print $1 }')"
	[ "$serial_before_hash" = "$serial_after_hash" ] ||
		die "Forced serial GRUB entry changed the target disk before confirmation"
	[ "$(grep -F -c 'OWRT_INSTALLER_BROKER_OWNER=' "$serial_log")" -eq 1 ] ||
		die "Forced serial GRUB entry emitted more than one owner"
	assert_log_not_contains "$serial_log" "OWRT_INSTALLER_UI_BACKEND=whiptail"
	log "Forced serial GRUB entry, framebuffer-independent line UI, and pre-confirm immutability passed"
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
	all|bios|uefi|hardware|vga|uefi-vga|graphics|serial|serial-console|serial-grub|install|storage|storage-bounded|storage-image|storage-custom|safe-upgrade|standard-upgrade|rescue|config-import|custom-build|custom-build-bios|custom-build-uefi|online|online-bios|online-uefi|local-disk|local-disk-bios|local-disk-uefi|local-disk-missing) ;;
	*) die "Usage: $0 [all|bios|uefi|hardware|vga|uefi-vga|graphics|serial|serial-console|serial-grub|install|storage|storage-bounded|storage-image|storage-custom|safe-upgrade|standard-upgrade|rescue|config-import|custom-build|custom-build-bios|custom-build-uefi|online|online-bios|online-uefi|local-disk|local-disk-bios|local-disk-uefi|local-disk-missing]" ;;
esac

[ -s "$ISO_IMAGE" ] || die "Hybrid ISO is missing. Run: make iso"
require_cmd timeout
require_cmd grep
require_cmd tail
case "$MODE" in
	all|hardware|vga|uefi-vga|graphics|serial|serial-console|serial-grub|install|storage|storage-bounded|storage-image|storage-custom|safe-upgrade|standard-upgrade|rescue|config-import|custom-build|custom-build-bios|custom-build-uefi|online|online-bios|online-uefi|local-disk|local-disk-bios|local-disk-uefi|local-disk-missing)
		require_cmd nc
		;;
esac
case "$MODE" in
	all|hardware|serial|serial-console|safe-upgrade|rescue|online|online-bios|online-uefi)
		[ -s "$ISO_STAGED_KERNEL" ] || die "Staged ISO kernel is missing. Run: make iso"
		[ -s "$ISO_STAGED_INITRAMFS" ] || die "Staged ISO initramfs is missing. Run: make iso"
		;;
esac
case "$MODE" in
	all|serial|serial-console|serial-grub)
		require_cmd sha256sum
		require_cmd truncate
		;;
esac
case "$MODE" in
	all|standard-upgrade|rescue|config-import|custom-build|custom-build-bios|custom-build-uefi|local-disk|local-disk-bios|local-disk-uefi)
		require_cmd gzip
		require_cmd fdisk
		[ -s "$TARGET_IMAGE" ] || die "Target image is missing. Run: make target"
		[ -x "$IMAGEBUILDER_DIR/staging_dir/host/bin/mcopy" ] ||
			die "ImageBuilder mcopy is required for local-disk smoke"
		;;
esac
case "$MODE" in
	all|vga|uefi-vga|graphics|install|storage|storage-bounded|storage-image|storage-custom|custom-build|custom-build-bios|custom-build-uefi)
		require_cmd od
		;;
esac
case "$MODE" in
	all|storage|storage-bounded|storage-image|storage-custom|safe-upgrade|standard-upgrade)
		require_cmd fdisk
		require_cmd sfdisk
		;;
esac
case "$MODE" in
all|standard-upgrade)
	require_cmd cmp
	require_cmd mkfs.ext4
	case "$QEMU_STANDARD_UPGRADE_SMP" in
		''|*[!0-9]*|0) die "QEMU_STANDARD_UPGRADE_SMP must be a positive integer" ;;
	esac
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
		run_local_disk_boot_smoke bios
		run_local_disk_boot_smoke uefi
		run_local_disk_missing_smoke
		run_hardware_flag_smoke
		run_vga_smoke
		run_uefi_vga_smoke
		run_serial_console_smoke
		run_serial_grub_smoke
		run_install_smoke
		run_storage_layout_smoke bounded
		run_storage_layout_smoke image
		run_storage_layout_smoke custom
		run_safe_upgrade_smoke
		run_standard_sysupgrade_smoke
		run_rescue_smoke
		run_config_import_smoke
		run_custom_build_smoke bios
		run_custom_build_smoke uefi
		;;
	bios)
		run_bios_smoke
		;;
	uefi)
		run_uefi_smoke
		;;
	hardware)
		run_hardware_flag_smoke
		;;
	vga)
		run_vga_smoke
		;;
	uefi-vga)
		run_uefi_vga_smoke
		;;
	graphics)
		run_vga_smoke
		run_uefi_vga_smoke
		;;
	serial-console)
		run_serial_console_smoke
		;;
	serial-grub)
		run_serial_grub_smoke
		;;
	serial)
		run_serial_console_smoke
		run_serial_grub_smoke
		;;
	install)
		run_install_smoke
		;;
	storage)
		run_storage_layout_smoke bounded
		run_storage_layout_smoke image
		run_storage_layout_smoke custom
		;;
	storage-bounded)
		run_storage_layout_smoke bounded
		;;
	storage-image)
		run_storage_layout_smoke image
		;;
	storage-custom)
		run_storage_layout_smoke custom
		;;
	safe-upgrade)
		run_safe_upgrade_smoke
		;;
	standard-upgrade)
		run_standard_sysupgrade_smoke
		;;
	rescue)
		run_rescue_smoke
		;;
	config-import)
		run_config_import_smoke
		;;
	custom-build)
		run_custom_build_smoke bios
		run_custom_build_smoke uefi
		;;
	custom-build-bios)
		run_custom_build_smoke bios
		;;
	custom-build-uefi)
		run_custom_build_smoke uefi
		;;
	online)
		run_online_install_smoke bios
		run_online_install_smoke uefi
		;;
	online-bios)
		run_online_install_smoke bios
		;;
	online-uefi)
		run_online_install_smoke uefi
		;;
	local-disk)
		run_local_disk_boot_smoke bios
		run_local_disk_boot_smoke uefi
		run_local_disk_missing_smoke
		;;
	local-disk-bios)
		run_local_disk_boot_smoke bios
		;;
	local-disk-uefi)
		run_local_disk_boot_smoke uefi
		;;
	local-disk-missing)
		run_local_disk_missing_smoke
		;;
esac

log "QEMU hybrid ISO smoke tests passed"
