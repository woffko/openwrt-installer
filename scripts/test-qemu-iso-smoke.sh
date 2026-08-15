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
	assert_log_contains "$log_file" "Please press Enter to activate this console."
	assert_log_contains "$log_file" "OpenWrt disk installer is managed by /etc/inittab on tty1."
	assert_log_contains "$log_file" "OWRT_INSTALLER_UI_BACKEND=whiptail"
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
	wait_for_ui_marker "$serial_log" "OWRT_INSTALLER_UI_READY=install-type" "$install_pid" "$QEMU_INSTALL_WAIT"
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
		printf 'cat /etc/config/system; cat /etc/config/network; cat /etc/openwrt-installer-release; if [ ! -e /etc/owrt-installer/interface-map ] && [ ! -e /etc/uci-defaults/98-installer-network ]; then echo OWRT_CONFIG_IMPORT_STALE_STATE_""ABSENT=1; fi\r'
	} | nc -N -U "$boot_serial_socket" >/dev/null 2>&1 ||
		die "Could not query config-import installed system console"
	wait_for_log_marker "$boot_serial_log" "OWRT_CONFIG_IMPORT_STALE_STATE_ABSENT=1" "$boot_pid" "$QEMU_INSTALL_WAIT"
	hmp_command "$boot_monitor_socket" quit
	wait "$boot_pid" || true

	assert_log_contains "$boot_serial_log" "option hostname 'imported-qemu'"
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
			;;
		uefi)
			online_image_type="ext4-combined-efi"
			online_boot_label="UEFI"
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
	ensure_qcow2 "$target_disk"

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
	all|bios|uefi|hardware|vga|install|config-import|online|online-bios|online-uefi|local-disk|local-disk-bios|local-disk-uefi|local-disk-missing) ;;
	*) die "Usage: $0 [all|bios|uefi|hardware|vga|install|config-import|online|online-bios|online-uefi|local-disk|local-disk-bios|local-disk-uefi|local-disk-missing]" ;;
esac

[ -s "$ISO_IMAGE" ] || die "Hybrid ISO is missing. Run: make iso"
require_cmd timeout
require_cmd grep
require_cmd tail
case "$MODE" in
	all|hardware|vga|install|config-import|online|online-bios|online-uefi|local-disk|local-disk-bios|local-disk-uefi|local-disk-missing)
		require_cmd nc
		;;
esac
case "$MODE" in
	all|hardware|online|online-bios|online-uefi)
		[ -s "$ISO_STAGED_KERNEL" ] || die "Staged ISO kernel is missing. Run: make iso"
		[ -s "$ISO_STAGED_INITRAMFS" ] || die "Staged ISO initramfs is missing. Run: make iso"
		;;
esac
case "$MODE" in
	all|config-import|local-disk|local-disk-bios|local-disk-uefi)
		require_cmd gzip
		require_cmd fdisk
		[ -s "$TARGET_IMAGE" ] || die "Target image is missing. Run: make target"
		[ -x "$IMAGEBUILDER_DIR/staging_dir/host/bin/mcopy" ] ||
			die "ImageBuilder mcopy is required for local-disk smoke"
		;;
esac
case "$MODE" in
	all|vga|install)
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
		run_local_disk_boot_smoke bios
		run_local_disk_boot_smoke uefi
		run_local_disk_missing_smoke
		run_hardware_flag_smoke
		run_vga_smoke
		run_install_smoke
		run_config_import_smoke
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
	install)
		run_install_smoke
		;;
	config-import)
		run_config_import_smoke
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
