#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INSTALLER="$PROJECT_DIR/files-installer/usr/sbin/owrt-install"
UI_LIB="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-ui"
TMPDIR="${TMPDIR:-/tmp}"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

shell_quote() {
	printf "'"
	printf '%s' "$1" | sed "s/'/'\\\\''/g"
	printf "'"
}

assert_contains() {
	file="$1"
	pattern="$2"
	if ! grep -F "$pattern" "$file" >/dev/null 2>&1; then
		printf '%s\n' "--- $file ---" >&2
		sed -n '1,160p' "$file" >&2 || true
		fail "Expected output to contain: $pattern"
	fi
}

assert_not_contains() {
	file="$1"
	pattern="$2"
	if grep -F "$pattern" "$file" >/dev/null 2>&1; then
		printf '%s\n' "--- $file ---" >&2
		sed -n '1,160p' "$file" >&2 || true
		fail "Output must not contain: $pattern"
	fi
}

run_line_stage_smoke() {
	log_file="$1"
	out_file="$2"

	OWRT_UI_MODE=line TERM=dumb sh -eu -c '
		. "$1"
		INSTALLER_VERSION=smoke
		setup_ui
		ui_install_stage "Write image" "Writing embedded OpenWrt image to /dev/test." "$2"
		ui_failure_screen "forced failure" "$2"
	' sh "$UI_LIB" "$log_file" > "$out_file" 2>&1

	assert_contains "$out_file" "stage: Write image"
	assert_contains "$out_file" "ERROR: forced failure"
	assert_contains "$out_file" "Log: $log_file"
	assert_contains "$out_file" "Recent log:"
	assert_contains "$out_file" "12:00:03 ERROR: forced"
}

run_line_menu_smoke() {
	work_dir="$1"
	out_file="$2"

	printf '2\n' |
		OWRT_UI_MODE=line TERM=dumb sh -eu -c '
			. "$1"
			MENU_LIST="$2/menu"
			setup_ui
			menu_reset
			menu_add "one" "First option"
			menu_add "two" "Second option"
			select_from_menu "Pick value" "value"
			printf "selected=%s\n" "$SELECTED_VALUE"
		' sh "$UI_LIB" "$work_dir" > "$out_file" 2>&1

	assert_contains "$out_file" "[1] First option"
	assert_contains "$out_file" "[2] Second option"
	assert_contains "$out_file" "selected=two"
}

run_ansi_stage_smoke() {
	work_dir="$1"
	log_file="$2"
	out_file="$3"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; ANSI pseudo-TTY smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/ansi-stage.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'INSTALLER_VERSION=smoke'
		printf '%s\n' 'setup_ui'
		printf 'ui_install_stage "Write image" "Writing embedded OpenWrt image to /dev/test." %s\n' "$(shell_quote "$log_file")"
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	OWRT_UI_MODE=ansi TERM=xterm script -q -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "ANSI pseudo-TTY smoke failed"

	assert_contains "$out_file" "OPENWRT HELLFORGE INSTALLER"
	assert_contains "$out_file" "Stage: Write image"
	assert_contains "$out_file" "Progress:"
	assert_contains "$out_file" "Recent log:"
}

run_ansi_menu_ctrl_c_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; ANSI Ctrl+C cleanup smoke skipped.\n'
		return 0
	fi

	if ! script -q -e -c true "$work_dir/script-return.out" >/dev/null 2>&1; then
		printf 'SKIP: script(1) has no usable -e support; ANSI Ctrl+C cleanup smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/ansi-menu-ctrl-c.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf 'OWRT_INSTALL_TEST_SOURCE_ONLY=1 UI_LIB=%s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'export OWRT_INSTALL_TEST_SOURCE_ONLY UI_LIB'
		printf '. %s\n' "$(shell_quote "$INSTALLER")"
		printf '%s\n' 'INSTALLER_VERSION=smoke'
		printf 'MENU_LIST=%s\n' "$(shell_quote "$work_dir/menu-ctrl-c")"
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'menu_reset'
		printf '%s\n' 'menu_add "one" "One"'
		printf '%s\n' 'menu_add "two" "Two"'
		printf '%s\n' 'select_from_menu "Interrupt cleanup" "value"'
		printf '%s\n' 'printf "unexpected-success\n"'
	} > "$harness"
	chmod +x "$harness"

	set +e
	( sleep 1; printf '\003' ) |
		OWRT_UI_MODE=ansi TERM=xterm script -q -e -c "$harness" "$out_file" >/dev/null 2>&1
	status="$?"
	set -e

	[ "$status" -eq 130 ] || fail "ANSI Ctrl+C cleanup smoke exited with $status instead of 130"
	assert_contains "$out_file" "OPENWRT HELLFORGE INSTALLER"
	assert_contains "$out_file" "$(printf '\033[?25h')"
	assert_contains "$out_file" "$(printf '\033[?1000l')"
	assert_not_contains "$out_file" "unexpected-success"
}

run_ansi_menu_esc_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; ANSI Esc cancel smoke skipped.\n'
		return 0
	fi

	if ! script -q -e -c true "$work_dir/script-esc-return.out" >/dev/null 2>&1; then
		printf 'SKIP: script(1) has no usable -e support; ANSI Esc cancel smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/ansi-menu-esc.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf 'OWRT_INSTALL_TEST_SOURCE_ONLY=1 UI_LIB=%s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'export OWRT_INSTALL_TEST_SOURCE_ONLY UI_LIB'
		printf '. %s\n' "$(shell_quote "$INSTALLER")"
		printf '%s\n' 'INSTALLER_VERSION=smoke'
		printf 'MENU_LIST=%s\n' "$(shell_quote "$work_dir/menu-esc")"
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'menu_reset'
		printf '%s\n' 'menu_add "one" "One"'
		printf '%s\n' 'menu_add "two" "Two"'
		printf '%s\n' 'select_from_menu "Esc cancel" "value"'
		printf '%s\n' 'printf "unexpected-success\n"'
	} > "$harness"
	chmod +x "$harness"

	set +e
	( sleep 1; printf '\033'; sleep 1; printf '\n' ) |
		OWRT_UI_MODE=ansi TERM=xterm script -q -e -c "$harness" "$out_file" >/dev/null 2>&1
	status="$?"
	set -e

	[ "$status" -eq 1 ] || fail "ANSI Esc cancel smoke exited with $status instead of 1"
	assert_contains "$out_file" "Esc cancel"
	assert_contains "$out_file" "ERROR: Selection cancelled"
	assert_contains "$out_file" "$(printf '\033[?25h')"
	assert_not_contains "$out_file" "unexpected-success"
}

run_dialog_mode_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; dialog fallback smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/dialog-mode.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'setup_ui'
		printf '%s\n' "printf \"mode=%s\\n\" \"\$UI_MODE_ACTUAL\""
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	OWRT_UI_MODE=dialog TERM=xterm script -q -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "dialog mode smoke failed"

	if command -v dialog >/dev/null 2>&1; then
		assert_contains "$out_file" "mode=dialog"
	else
		assert_contains "$out_file" "mode=ansi"
	fi
	assert_not_contains "$out_file" "mode=line"
}

run_terminal_size_smoke_case() {
	work_dir="$1"
	rows="$2"
	cols="$3"
	expected="$4"
	out_file="$work_dir/terminal-${cols}x${rows}.out"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; terminal-size smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/terminal-${cols}x${rows}.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf 'stty rows %s cols %s 2>/dev/null || true\n' "$rows" "$cols"
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'setup_ui'
		printf '%s\n' "printf \"mode=%s width=%s height=%s\\n\" \"\$UI_MODE_ACTUAL\" \"\$UI_WIDTH\" \"\$UI_HEIGHT\""
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	OWRT_UI_MODE=auto TERM=xterm script -q -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "terminal-size smoke failed for ${cols}x${rows}"

	case "$expected" in
		line)
			assert_contains "$out_file" "mode=line"
			;;
		tui)
			assert_not_contains "$out_file" "mode=line"
			;;
		*)
			fail "Unsupported terminal-size expectation: $expected"
			;;
	esac
}

run_terminal_size_smoke() {
	work_dir="$1"

	run_terminal_size_smoke_case "$work_dir" 25 80 tui
	run_terminal_size_smoke_case "$work_dir" 30 100 tui
	run_terminal_size_smoke_case "$work_dir" 19 79 line
}

[ -r "$INSTALLER" ] || fail "Installer not found: $INSTALLER"
[ -r "$UI_LIB" ] || fail "UI library not found: $UI_LIB"

work_dir="$(mktemp -d "$TMPDIR/owrt-ui-smoke.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT INT TERM

log_file="$work_dir/owrt-installer.log"
cat > "$log_file" <<'EOF'
12:00:01 INFO: session started
12:00:02 INFO: payload verified
12:00:03 ERROR: forced
EOF

run_line_stage_smoke "$log_file" "$work_dir/line-stage.out"
run_line_menu_smoke "$work_dir" "$work_dir/line-menu.out"
run_ansi_stage_smoke "$work_dir" "$log_file" "$work_dir/ansi-stage.out"
run_ansi_menu_ctrl_c_smoke "$work_dir" "$work_dir/ansi-menu-ctrl-c.out"
run_ansi_menu_esc_smoke "$work_dir" "$work_dir/ansi-menu-esc.out"
run_dialog_mode_smoke "$work_dir" "$work_dir/dialog-mode.out"
run_terminal_size_smoke "$work_dir"

printf 'UI smoke tests passed.\n'
