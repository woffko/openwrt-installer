#!/bin/sh

set -eu

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

SMOKE_DIR="$BUILD_DIR/qemu-local-mouse-smoke"
KERNEL_IMAGE="${KERNEL_IMAGE:-$BUILD_DIR/hybrid-iso/root/boot/vmlinuz}"
INITRAMFS_IMAGE="${INITRAMFS_IMAGE:-$BUILD_DIR/hybrid-iso/root/boot/initramfs.cpio.gz}"
QEMU_WAIT="${QEMU_MOUSE_WAIT:-90}"
QEMU_TIMEOUT="${QEMU_MOUSE_TIMEOUT:-180s}"
QEMU_UI_SETTLE="${QEMU_UI_SETTLE:-1}"
QEMU_ACCEL="${QEMU_ACCEL:-tcg}"
QEMU_MEMORY="${QEMU_MEMORY:-1024}"
QEMU_SMP="${QEMU_SMP:-2}"
LOCAL_QEMU_ROOT="$BUILD_DIR/qemu-local/root"
QEMU_PID=""
SERIAL_LOG=""
SERIAL_SOCKET=""
MONITOR_SOCKET=""
QEMU_ENV_PREFIX=""
QEMU_L_ARG=""

find_qemu_system() {
	if command -v qemu-system-x86_64 >/dev/null 2>&1; then
		command -v qemu-system-x86_64
		return 0
	fi
	[ -x "$LOCAL_QEMU_ROOT/usr/bin/qemu-system-x86_64" ] || return 1
	printf '%s\n' "$LOCAL_QEMU_ROOT/usr/bin/qemu-system-x86_64"
}

configure_qemu_env() {
	case "$QEMU_SYSTEM" in
		"$LOCAL_QEMU_ROOT"/*)
			qemu_lib="$LOCAL_QEMU_ROOT/usr/lib/x86_64-linux-gnu:$LOCAL_QEMU_ROOT/lib/x86_64-linux-gnu"
			QEMU_ENV_PREFIX="LD_LIBRARY_PATH=$qemu_lib QEMU_MODULE_DIR=$LOCAL_QEMU_ROOT/usr/lib/x86_64-linux-gnu/qemu QEMU_AUDIO_DRV=none"
			QEMU_L_ARG="$LOCAL_QEMU_ROOT/usr/share/qemu"
			;;
		*) QEMU_ENV_PREFIX="QEMU_AUDIO_DRV=none" ;;
	esac
}

wait_for_marker() {
	marker="$1"
	elapsed=0
	while [ "$elapsed" -lt "$QEMU_WAIT" ]; do
		if [ -r "$SERIAL_LOG" ] && grep -F "$marker" "$SERIAL_LOG" >/dev/null 2>&1; then
			return 0
		fi
		if ! kill -0 "$QEMU_PID" 2>/dev/null; then
			wait "$QEMU_PID" || true
			tail -n 100 "$SERIAL_LOG" >&2 2>/dev/null || true
			die "QEMU exited before marker: $marker"
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done
	tail -n 100 "$SERIAL_LOG" >&2 2>/dev/null || true
	die "Timed out waiting for marker: $marker"
}

assert_marker() {
	marker="$1"
	grep -F "$marker" "$SERIAL_LOG" >/dev/null 2>&1 ||
		die "Missing marker '$marker' in $SERIAL_LOG"
}

hmp() {
	printf '%s\n' "$*" | nc -N -U "$MONITOR_SOCKET" >/dev/null 2>&1 ||
		die "Could not send QEMU monitor command: $*"
}

hmp_keys() {
	sleep "$QEMU_UI_SETTLE"
	{
		for key in "$@"; do
			printf 'sendkey %s\n' "$key"
			sleep 0.15
		done
	} | nc -N -U "$MONITOR_SOCKET" >/dev/null 2>&1 ||
		die "Could not send keys through QEMU monitor"
}

serial_command() {
	command="$1"
	{ printf '\r'; sleep 1; printf '%s\r' "$command"; } |
		nc -N -U "$SERIAL_SOCKET" >/dev/null 2>&1 ||
		die "Could not send command through QEMU serial console"
}

stop_vm() {
	[ -n "$QEMU_PID" ] || return 0
	if kill -0 "$QEMU_PID" 2>/dev/null; then
		if [ -S "$MONITOR_SOCKET" ]; then
			hmp quit || true
		else
			kill "$QEMU_PID" 2>/dev/null || true
		fi
	fi
	wait "$QEMU_PID" 2>/dev/null || true
	QEMU_PID=""
}

start_vm() {
	name="$1"
	extra_cmdline="$2"
	shift 2
	SERIAL_LOG="$SMOKE_DIR/$name-serial.log"
	SERIAL_SOCKET="$SMOKE_DIR/$name-serial.sock"
	MONITOR_SOCKET="$SMOKE_DIR/$name-monitor.sock"
	qemu_log="$SMOKE_DIR/$name-qemu.log"
	disk="$SMOKE_DIR/$name.raw"

	stop_vm
	rm -f "$SERIAL_LOG" "$SERIAL_SOCKET" "$MONITOR_SOCKET" "$qemu_log" "$disk"
	truncate -s 1G "$disk"

	if [ -n "$QEMU_L_ARG" ]; then
		# shellcheck disable=SC2086 # Controlled key=value environment entries.
		timeout "$QEMU_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" -L "$QEMU_L_ARG" \
			-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
			-display none -vga std -kernel "$KERNEL_IMAGE" -initrd "$INITRAMFS_IMAGE" \
			-append "console=tty1 console=ttyS0,115200n8 rdinit=/init owrt.mouse=1 $extra_cmdline" \
			-chardev "socket,id=serial0,path=$SERIAL_SOCKET,server=on,wait=off,logfile=$SERIAL_LOG" \
			-serial chardev:serial0 -monitor "unix:$MONITOR_SOCKET,server=on,wait=off" \
			-drive "file=$disk,format=raw,if=virtio" \
			-nic user,model=e1000 -nic user,model=e1000 "$@" > "$qemu_log" 2>&1 &
	else
		# shellcheck disable=SC2086 # Controlled key=value environment entries.
		timeout "$QEMU_TIMEOUT" env $QEMU_ENV_PREFIX "$QEMU_SYSTEM" \
			-machine "q35,accel=$QEMU_ACCEL" -m "$QEMU_MEMORY" -smp "$QEMU_SMP" \
			-display none -vga std -kernel "$KERNEL_IMAGE" -initrd "$INITRAMFS_IMAGE" \
			-append "console=tty1 console=ttyS0,115200n8 rdinit=/init owrt.mouse=1 $extra_cmdline" \
			-chardev "socket,id=serial0,path=$SERIAL_SOCKET,server=on,wait=off,logfile=$SERIAL_LOG" \
			-serial chardev:serial0 -monitor "unix:$MONITOR_SOCKET,server=on,wait=off" \
			-drive "file=$disk,format=raw,if=virtio" \
			-nic user,model=e1000 -nic user,model=e1000 "$@" > "$qemu_log" 2>&1 &
	fi
	QEMU_PID=$!
	wait_for_marker "OWRT_INSTALLER_UI_READY=target-disk"
}

click_target_ok() {
	# GPM starts at cell 80x25 on the QEMU 160x50 console. Its default
	# scaling maps ten small X deltas and twenty Y deltas to one cell.
	{
		for _ in $(seq 1 15); do
			printf 'mouse_move -10 0\n'
			sleep 0.1
		done
		printf 'mouse_move 0 20\nmouse_move 0 20\n'
		sleep 0.2
		printf 'mouse_button 1\n'
		sleep 0.2
		printf 'mouse_button 0\n'
	} | nc -N -U "$MONITOR_SOCKET" >/dev/null 2>&1 ||
		die "Could not send calibrated USB mouse click"
}

run_usb_click_and_crash() {
	log "Testing USB relative mouse click and daemon-crash keyboard fallback"
	start_vm usb-relative "" -device qemu-xhci -device usb-mouse
	assert_marker "QEMU QEMU USB Mouse"
	assert_marker "OWRT_INSTALLER_LOCAL_MOUSE=active"
	assert_marker "OWRT_INSTALLER_LOCAL_MOUSE_SOCKET_MODE=600"
	click_target_ok
	wait_for_marker "OWRT_INSTALLER_UI_READY=lan-interface"
	serial_command "killall -9 gpm; echo OWRT_MOUSE_DAEMON_CRASHED"
	wait_for_marker "OWRT_MOUSE_DAEMON_CRASHED"
	hmp_keys ret
	wait_for_marker "OWRT_INSTALLER_UI_READY=wan-interface-auto"
	serial_command "/usr/libexec/owrt-installer-local-mouse stop; if [ ! -S /dev/gpmctl ] && [ ! -e /var/run/gpm.pid ] && [ ! -e /tmp/owrt-installer-mouse/state ]; then echo OWRT_MOUSE_CRASH_RUNTIME_CLEAN; else echo OWRT_MOUSE_CRASH_RUNTIME_DIRTY; fi"
	wait_for_marker "OWRT_MOUSE_CRASH_RUNTIME_CLEAN"
	stop_vm
}

run_ps2_activation() {
	log "Testing PS/2 relative mouse activation"
	start_vm ps2-relative ""
	assert_marker "OWRT_INSTALLER_LOCAL_MOUSE=active"
	assert_marker "OWRT_INSTALLER_LOCAL_MOUSE_SOCKET_MODE=600"
	stop_vm
}

run_absolute_rejection() {
	log "Testing absolute-only USB tablet rejection"
	start_vm usb-tablet "module_blacklist=psmouse" -device qemu-xhci -device usb-tablet
	assert_marker "QEMU QEMU USB Tablet"
	assert_marker "OWRT_INSTALLER_LOCAL_MOUSE=keyboard-fallback"
	if grep -F "OWRT_INSTALLER_LOCAL_MOUSE=active" "$SERIAL_LOG" >/dev/null 2>&1; then
		die "Absolute-only tablet unexpectedly enabled local mouse"
	fi
	hmp_keys ret
	wait_for_marker "OWRT_INSTALLER_UI_READY=lan-interface"
	stop_vm
}

run_exact_confirmation_cleanup() {
	log "Testing GPM shutdown before exact ERASE confirmation"
	start_vm exact-confirm "" -device qemu-xhci -device usb-mouse
	assert_marker "OWRT_INSTALLER_LOCAL_MOUSE=active"
	hmp_keys ret
	wait_for_marker "OWRT_INSTALLER_UI_READY=lan-interface"
	hmp_keys ret
	wait_for_marker "OWRT_INSTALLER_UI_READY=wan-interface-auto"
	hmp_keys ret
	wait_for_marker "OWRT_INSTALLER_UI_READY=lan-ip"
	hmp_keys ret
	wait_for_marker "OWRT_INSTALLER_UI_READY=wan-mode"
	hmp_keys ret
	wait_for_marker "OWRT_INSTALLER_UI_READY=wan6-mode"
	hmp_keys ret
	wait_for_marker "OWRT_INSTALLER_UI_READY=review-summary"
	hmp_keys ret
	wait_for_marker "OWRT_INSTALLER_UI_READY=review-action"
	hmp_keys ret
	wait_for_marker "OWRT_INSTALLER_UI_READY=final-erase-info"
	hmp_keys ret
	wait_for_marker "OWRT_INSTALLER_UI_READY=exact-erase"
	assert_marker "OWRT_INSTALLER_LOCAL_MOUSE=stopped"

	stop_line="$(grep -n -F 'OWRT_INSTALLER_LOCAL_MOUSE=stopped' "$SERIAL_LOG" | tail -n 1 | cut -d: -f1)"
	exact_line="$(grep -n -F 'OWRT_INSTALLER_UI_READY=exact-erase' "$SERIAL_LOG" | tail -n 1 | cut -d: -f1)"
	[ "$stop_line" -lt "$exact_line" ] || die "Mouse stop marker was not emitted before exact confirmation"

	serial_command "if [ ! -S /dev/gpmctl ] && [ ! -e /var/run/gpm.pid ] && [ ! -e /tmp/owrt-installer-mouse/state ]; then echo OWRT_MOUSE_RUNTIME_CLEAN; else echo OWRT_MOUSE_RUNTIME_DIRTY; fi"
	wait_for_marker "OWRT_MOUSE_RUNTIME_CLEAN"
	stop_vm
}

cleanup() {
	stop_vm
}

trap cleanup EXIT INT TERM

[ -s "$KERNEL_IMAGE" ] || die "Hybrid ISO kernel is missing. Run: make iso"
[ -s "$INITRAMFS_IMAGE" ] || die "Hybrid ISO initramfs is missing. Run: make iso"
require_cmd timeout
require_cmd nc
require_cmd truncate
require_cmd seq
mkdir -p "$SMOKE_DIR"

QEMU_SYSTEM="$(find_qemu_system)" || die "qemu-system-x86_64 is required"
configure_qemu_env

run_usb_click_and_crash
run_ps2_activation
run_absolute_rejection
run_exact_confirmation_cleanup

log "QEMU local-console mouse acceptance passed"
