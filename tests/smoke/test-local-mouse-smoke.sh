#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
HELPER="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-local-mouse"
INSTALLER="$PROJECT_DIR/files-installer/usr/sbin/owrt-install"
UI_LIB="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-ui"
GPM_PATCH="$PROJECT_DIR/packages/gpm-daemon/patches/010-modern-toolchain.patch"
NEWT_POINTER_PATCH="$PROJECT_DIR/packages/newt-gpm/patches/020-gpm-visible-pointer.patch"
MOUSEDEV_PACKAGE="$PROJECT_DIR/packages/input-mousedev/Makefile"
TMPDIR="${TMPDIR:-/tmp}"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	file="$1"
	pattern="$2"
	grep -F -- "$pattern" "$file" >/dev/null 2>&1 ||
		fail "Expected $file to contain: $pattern"
}

run_aggregate_device_smoke() {
	work_dir="$1/aggregate-device"
	mkdir -p "$work_dir/dev"
	: > "$work_dir/dev/mice"

	selected="$(
		OWRT_LOCAL_MOUSE_TEST_MODE=1 \
		OWRT_LOCAL_MOUSE_INPUT_DEV_ROOT="$work_dir/dev" \
			"$HELPER" device
	)"
	[ "$selected" = "$work_dir/dev/mice" ] ||
		fail "Aggregate pointer path returned: $selected"

	rm -f "$work_dir/dev/mice"
	if OWRT_LOCAL_MOUSE_TEST_MODE=1 \
		OWRT_LOCAL_MOUSE_INPUT_DEV_ROOT="$work_dir/dev" \
		"$HELPER" device >/dev/null 2>&1
	then
		fail "Missing mousedev aggregate must not be accepted"
	fi
}

run_confirmation_lifecycle_smoke() {
	work_dir="$1/confirmation"
	mkdir -p "$work_dir"
	call_log="$work_dir/helper.calls"
	fake_helper="$work_dir/mouse-helper"
	cat > "$fake_helper" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$OWRT_MOUSE_TEST_CALLS"
EOF
	chmod +x "$fake_helper"

	printf 'ERASE /dev/testdisk\n' |
		OWRT_MOUSE_TEST_CALLS="$call_log" \
		OWRT_INSTALL_TEST_SOURCE_ONLY=1 \
		OWRT_LOCAL_MOUSE_HELPER="$fake_helper" \
		TMPDIR="$work_dir" UI_LIB="$UI_LIB" \
		sh -eu -c '
			. "$1"
			TARGET=/dev/testdisk
			LOCAL_MOUSE_ACTIVE=1
			ui_confirm_erase_screen() { :; }
			autostart_serial_marker() { :; }
			confirm_erase
			[ "$LOCAL_MOUSE_ACTIVE" = "1" ]
			cleanup
		' sh "$INSTALLER" >/dev/null

	[ "$(sed -n '1p' "$call_log")" = "stop" ] ||
		fail "GPM was not stopped before exact confirmation"
	[ "$(sed -n '2p' "$call_log")" = "start" ] ||
		fail "GPM was not restarted after exact confirmation"
	[ "$(sed -n '3p' "$call_log")" = "stop" ] ||
		fail "GPM was not stopped during installer cleanup"
}

run_crashed_daemon_cleanup_smoke() {
	work_dir="$1/crashed-daemon"
	state_dir="$work_dir/state"
	mkdir -p "$state_dir"
	pid_file="$work_dir/gpm.pid"
	socket_file="$work_dir/gpmctl"
	missing_pid=999999
	printf '%s 0 /dev/input/mice\n' "$missing_pid" > "$state_dir/state"
	printf '%s\n' "$missing_pid" > "$pid_file"
	: > "$socket_file"

	OWRT_LOCAL_MOUSE_STATE_DIR="$state_dir" \
	OWRT_LOCAL_MOUSE_GPM_PID_FILE="$pid_file" \
	OWRT_LOCAL_MOUSE_GPM_SOCKET="$socket_file" \
		"$HELPER" stop >/dev/null

	[ ! -e "$state_dir/state" ] || fail "Crashed-daemon state was not removed"
	[ ! -e "$pid_file" ] || fail "Crashed-daemon PID file was not removed"
	[ ! -e "$socket_file" ] || fail "Crashed-daemon socket was not removed"
}

[ -x "$HELPER" ] || fail "Local mouse helper is not executable"
assert_contains "$GPM_PATCH" "chmod(GPM_NODE_CTL,0600);"
assert_contains "$GPM_PATCH" "daemon/processrequest.c\\"
assert_contains "$GPM_PATCH" "sizeof(struct input_event)"
assert_contains "$GPM_PATCH" "thisevent.value ? (state->buttons | GPM_B_LEFT)"
[ ! -e "$PROJECT_DIR/packages/gpm-daemon/patches/020-evdev-absolute-pointer.patch" ] ||
	fail "Custom GPM EV_ABS decoder must be removed"
assert_contains "$PROJECT_DIR/packages/gpm-daemon/Makefile" "PKG_RELEASE:=5"
assert_contains "$PROJECT_DIR/packages/gpm-daemon/Makefile" "DEPENDS:=+libc +libgcc"
assert_contains "$PROJECT_DIR/packages/newt-gpm/Makefile" "PKG_RELEASE:=4"
assert_contains "$NEWT_POINTER_PATCH" "GPM_MOVE | GPM_DRAG | GPM_DOWN | GPM_UP"
assert_contains "$NEWT_POINTER_PATCH" "ioctl(STDIN_FILENO, TIOCLINUX, &selection)"
assert_contains "$NEWT_POINTER_PATCH" "newtGpmSetPointer(&event, 3)"
assert_contains "$NEWT_POINTER_PATCH" "newtGpmSetPointer(NULL, 4)"
assert_contains "$PROJECT_DIR/packages/newt-gpm/patches/030-multiline-backtitle.patch" \
	"drawBacktitle(backtitleText)"
assert_contains "$PROJECT_DIR/packages/newt-gpm/patches/030-multiline-backtitle.patch" \
	"backtitleWidth(text)"
assert_contains "$PROJECT_DIR/packages/newt-gpm/patches/030-multiline-backtitle.patch" \
	"newtDrawRootText(column, row++, line)"
assert_contains "$PROJECT_DIR/packages/newt-gpm/patches/030-multiline-backtitle.patch" \
	"SLtt_Screen_Rows - backtitleRows"
assert_contains "$MOUSEDEV_PACKAGE" "PKG_VERSION:=6.12.94"
assert_contains "$MOUSEDEV_PACKAGE" "mousedev.ko"
# shellcheck disable=SC2016 # Assert literal OpenWrt make syntax.
assert_contains "$MOUSEDEV_PACKAGE" 'AUTOLOAD:=$(call AutoProbe,mousedev)'
# shellcheck disable=SC2016 # Assert literal runtime parameter expansion.
assert_contains "$HELPER" 'MOUSE_DEVICE="${OWRT_LOCAL_MOUSE_DEVICE:-$INPUT_DEV_ROOT/mice}"'
# shellcheck disable=SC2016 # Assert literal GPM command construction.
assert_contains "$HELPER" '"$GPM_BIN" -m "$device" -t imps2 -A'
assert_contains "$PROJECT_DIR/profiles/packages-installer.txt" "kmod-input-mousedev"
assert_contains "$PROJECT_DIR/profiles/packages-installer.txt" "coreutils-stat"
if grep -F 'vt.cur_default=6' "$PROJECT_DIR/iso/boot/grub/grub.cfg" >/dev/null 2>&1; then
	fail "Local mouse must not reuse the blinking text cursor"
fi

work_dir="$(mktemp -d "$TMPDIR/owrt-local-mouse-smoke.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT INT TERM

run_aggregate_device_smoke "$work_dir"
run_confirmation_lifecycle_smoke "$work_dir"
run_crashed_daemon_cleanup_smoke "$work_dir"

printf 'Local console mouse smoke tests passed.\n'
