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
	if ! grep -F -- "$pattern" "$file" >/dev/null 2>&1; then
		printf '%s\n' "--- $file ---" >&2
		sed -n '1,160p' "$file" >&2 || true
		fail "Expected output to contain: $pattern"
	fi
}

assert_not_contains() {
	file="$1"
	pattern="$2"
	if grep -F -- "$pattern" "$file" >/dev/null 2>&1; then
		printf '%s\n' "--- $file ---" >&2
		sed -n '1,160p' "$file" >&2 || true
		fail "Output must not contain: $pattern"
	fi
}

strip_ansi_file() {
	file="$1"
	esc="$(printf '\033')"
	sed "s/${esc}\\[[0-9;?]*[A-Za-z]//g" "$file" | tr -d '\r'
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

run_payload_title_smoke() {
	out_file="$1"

	OWRT_UI_MODE=line TERM=dumb sh -eu -c '
		. "$1"
		printf "default=%s\n" "$UI_BACKTITLE"
		ui_set_payload_version "25.12.5"
		printf "selected=%s payload=%s\n" "$UI_BACKTITLE" "$UI_PAYLOAD_VERSION"
		ui_set_payload_version "25.12.5 invalid"
		printf "invalid=%s payload=%s\n" "$UI_BACKTITLE" "$UI_PAYLOAD_VERSION"
	' sh "$UI_LIB" > "$out_file" 2>&1

	assert_contains "$out_file" "default=OpenWrt Hellforge Installer"
	assert_contains "$out_file" \
		"selected=OpenWrt Hellforge Installer | OpenWrt 25.12.5 payload=25.12.5"
	assert_contains "$out_file" "invalid=OpenWrt Hellforge Installer payload="
}

run_line_progress_stream_smoke() {
	work_dir="$1"
	out_file="$2"

	OWRT_UI_MODE=line TERM=dumb sh -eu -c '
		. "$1"
		progress_fifo="$2/line-progress.fifo"
		rm -f "$progress_fifo"
		mkfifo "$progress_fifo"
		(printf "0\n42\ninvalid\n100\n" > "$progress_fifo") &
		writer_pid=$!
		setup_ui
		ui_install_progress_stream "$progress_fifo" "Write image" "Writing test image." ""
		wait "$writer_pid"
		rm -f "$progress_fifo"
	' sh "$UI_LIB" "$work_dir" > "$out_file" 2>&1

	assert_contains "$out_file" "write progress: 0%"
	assert_contains "$out_file" "write progress: 42%"
	assert_contains "$out_file" "write progress: 100%"
	assert_not_contains "$out_file" "invalid%"
}

run_line_pppoe_wizard_smoke() {
	work_dir="$1"
	out_file="$2"
	marker_file="$work_dir/pppoe-wizard.markers"

	printf '%s\n' \
		'2' \
		'subscriber@example.net' \
		'!back' \
		'' \
		'smoke-secret' \
		'3' \
		'' \
		'1' |
		OWRT_INSTALL_TEST_SOURCE_ONLY=1 UI_LIB="$UI_LIB" OWRT_UI_MODE=line TERM=dumb \
		TMPDIR="$work_dir" sh -eu -c '
			. "$1"
			marker_file="$2"
			autostart_serial_marker() { printf "%s\n" "$1" >> "$marker_file"; }
			AUTO_STARTED=1
			setup_ui
			select_wan_settings
			printf "result proto=%s user=%s password_length=%s wan6=%s\n" \
				"$WAN_PROTO" "$WAN_PPP_USERNAME" "${#WAN_PPP_PASSWORD}" "$WAN6_PROTO"
			WAN_PPP_PASSWORD=""
			cleanup
		' sh "$INSTALLER" "$marker_file" > "$out_file" 2>&1 ||
		fail "line PPPoE wizard smoke failed"

	assert_contains "$out_file" "PPPoE username"
	assert_contains "$out_file" "Step 1 of 2"
	assert_contains "$out_file" "PPPoE password"
	assert_contains "$out_file" "Step 2 of 2"
	assert_contains "$out_file" \
		"result proto=pppoe user=subscriber@example.net password_length=12 wan6=dhcpv6"
	assert_not_contains "$out_file" "smoke-secret"
	[ "$(sed -n '1p' "$marker_file")" = "OWRT_INSTALLER_UI_READY=wan-mode" ] ||
		fail "PPPoE wizard did not start at WAN mode"
	[ "$(sed -n '2p' "$marker_file")" = "OWRT_INSTALLER_UI_READY=pppoe-username" ] ||
		fail "PPPoE username marker is missing"
	[ "$(sed -n '3p' "$marker_file")" = "OWRT_INSTALLER_UI_READY=pppoe-password" ] ||
		fail "PPPoE password marker is missing"
	[ "$(sed -n '4p' "$marker_file")" = "OWRT_INSTALLER_UI_READY=pppoe-username" ] ||
		fail "Back from PPPoE password did not return to username"
	[ "$(sed -n '5p' "$marker_file")" = "OWRT_INSTALLER_UI_READY=pppoe-password" ] ||
		fail "PPPoE password was not reopened after username"
	[ "$(sed -n '6p' "$marker_file")" = "OWRT_INSTALLER_UI_READY=wan6-mode" ] ||
		fail "PPPoE wizard did not continue to WAN IPv6"
	[ "$(sed -n '7p' "$marker_file")" = "OWRT_INSTALLER_UI_READY=pppoe-password" ] ||
		fail "Back from WAN IPv6 did not return to PPPoE password"
	[ "$(sed -n '8p' "$marker_file")" = "OWRT_INSTALLER_UI_READY=wan6-mode" ] ||
		fail "PPPoE wizard did not return to WAN IPv6"
	[ "$(wc -l < "$marker_file" | tr -d ' ')" = "8" ] ||
		fail "PPPoE wizard emitted unexpected UI markers"
}

run_whiptail_progress_stream_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; whiptail progress smoke skipped.\n'
		return 0
	fi

	fake_bin="$work_dir/progress-whiptail-bin"
	mkdir -p "$fake_bin"
	# shellcheck disable=SC2016
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' '[ "${1:-}" = "--version" ] && exit 0'
		printf '%s\n' 'printf "%s\n" "$*" > "$WHIPTAIL_ARGS"'
		printf '%s\n' 'cat > "$WHIPTAIL_INPUT"'
	} > "$fake_bin/whiptail"
	chmod +x "$fake_bin/whiptail"

	harness="$work_dir/whiptail-progress.sh"
	# shellcheck disable=SC2016
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf 'progress_fifo=%s\n' "$(shell_quote "$work_dir/whiptail-progress.fifo")"
		printf 'marker_file=%s\n' "$(shell_quote "$work_dir/whiptail-progress.markers")"
		printf '%s\n' 'autostart_serial_marker() { printf "%s\n" "$1" >> "$marker_file"; }'
		printf '%s\n' 'rm -f "$progress_fifo" "$marker_file"'
		printf '%s\n' 'mkfifo "$progress_fifo"'
		printf '%s\n' '(printf "0\n37\n100\n" > "$progress_fifo") &'
		printf '%s\n' 'writer_pid=$!'
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'ui_set_payload_version "25.12.5"'
		printf '%s\n' 'ui_install_progress_stream "$progress_fifo" "Write image" "Writing test image." ""'
		printf '%s\n' 'wait "$writer_pid"'
		printf '%s\n' 'rm -f "$progress_fifo"'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	WHIPTAIL_ARGS="$work_dir/whiptail-progress.args" \
	WHIPTAIL_INPUT="$work_dir/whiptail-progress.input" \
	PATH="$fake_bin:$PATH" OWRT_UI_MODE=whiptail TERM=xterm \
		script -q -e -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "Whiptail progress stream smoke failed"

	assert_contains "$work_dir/whiptail-progress.args" \
		"--fb --backtitle OpenWrt Hellforge Installer | OpenWrt 25.12.5 --title Install --gauge"
	assert_contains "$work_dir/whiptail-progress.input" "0"
	assert_contains "$work_dir/whiptail-progress.input" "37"
	assert_contains "$work_dir/whiptail-progress.input" "100"
	assert_contains "$work_dir/whiptail-progress.markers" "OWRT_INSTALLER_WRITE_PROGRESS=37"
	assert_contains "$work_dir/whiptail-progress.markers" "OWRT_INSTALLER_WRITE_PROGRESS=100"
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

run_ansi_menu_snapshot_smoke() {
	work_dir="$1"
	out_file="$2"
	clean_file="$3"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; ANSI menu snapshot smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/ansi-menu-snapshot.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'INSTALLER_VERSION=smoke'
		printf 'MENU_LIST=%s\n' "$(shell_quote "$work_dir/menu-snapshot")"
		printf '%s\n' 'stty rows 25 cols 80 2>/dev/null || true'
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'ui_set_payload_version "25.12.5"'
		printf '%s\n' 'menu_reset'
		printf '%s\n' 'menu_warning "WARNING: selected disk will be erased after final confirmation."'
		printf '%s\n' 'menu_add "/dev/sda" "/dev/sda 119.2G SSD removable=no live=no"'
		printf '%s\n' 'menu_add "/dev/nvme0n1" "/dev/nvme0n1 476.9G NVMe removable=no live=no"'
		printf '%s\n' 'render_arrow_menu "Select target disk" 1'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	OWRT_UI_MODE=ansi TERM=xterm script -q -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "ANSI menu snapshot smoke failed"
	strip_ansi_file "$out_file" > "$clean_file"

	assert_contains "$clean_file" "OPENWRT HELLFORGE INSTALLER"
	assert_contains "$clean_file" "OPENWRT HELLFORGE INSTALLER | OpenWrt 25.12.5 | smoke"
	assert_contains "$clean_file" "Steps: [DISK] ->  STORAGE  ->  LAN  ->  WAN  ->  REVIEW  ->  INSTALL"
	assert_contains "$clean_file" "Select target disk"
	assert_contains "$clean_file" "WARNING: selected disk will be erased after final confirmation."
	assert_contains "$clean_file" "> /dev/sda 119.2G SSD removable=no live=no"
	assert_contains "$clean_file" "  /dev/nvme0n1 476.9G NVMe removable=no live=no"
	assert_contains "$clean_file" "Up/Down Move  Enter/Click Select  Wheel Scroll  Esc/q Cancel"
	assert_not_contains "$clean_file" "$(printf '\033')"
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

run_ansi_menu_arrow_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; ANSI arrow smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/ansi-menu-arrow.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'INSTALLER_VERSION=smoke'
		printf 'MENU_LIST=%s\n' "$(shell_quote "$work_dir/menu-arrow")"
		printf '%s\n' 'stty rows 25 cols 80 2>/dev/null || true'
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'menu_reset'
		printf '%s\n' 'menu_add "one" "First option"'
		printf '%s\n' 'menu_add "two" "Second option"'
		printf '%s\n' 'select_from_menu "Arrow selection" "option"'
		# shellcheck disable=SC2016
		printf '%s\n' 'printf "selected=%s\n" "$SELECTED_VALUE"'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	( sleep 1; printf '\033[B'; sleep 1; printf '\n' ) |
		OWRT_UI_MODE=ansi OWRT_UI_NO_MOUSE=1 TERM=xterm \
		script -q -e -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "ANSI arrow selection smoke failed"

	assert_contains "$out_file" "selected=two"
}

run_ansi_menu_mouse_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; ANSI mouse smoke skipped.\n'
		return 0
	fi

	if ! script -q -e -c true "$work_dir/script-mouse-return.out" >/dev/null 2>&1; then
		printf 'SKIP: script(1) has no usable -e support; ANSI mouse smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/ansi-menu-mouse.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'INSTALLER_VERSION=smoke'
		printf 'MENU_LIST=%s\n' "$(shell_quote "$work_dir/menu-mouse")"
		printf '%s\n' 'stty rows 25 cols 80 2>/dev/null || true'
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'menu_reset'
		printf '%s\n' 'menu_warning "WARNING: selected disk will be erased after final confirmation."'
		printf '%s\n' 'menu_add "one" "First disk"'
		printf '%s\n' 'menu_add "two" "Second disk"'
		printf '%s\n' 'select_from_menu "Select target disk" "target disk"'
		# shellcheck disable=SC2016
		printf '%s\n' 'printf "selected=%s\n" "$SELECTED_VALUE"'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	# At 80x25 with one warning line, the second item is rendered on row 11.
	( sleep 1; printf '\033[<0;12;11M' ) |
		OWRT_UI_MODE=ansi TERM=xterm script -q -e -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "ANSI mouse selection smoke failed"

	assert_contains "$out_file" "$(printf '\033[?1000h')"
	assert_contains "$out_file" "$(printf '\033[?1006h')"
	assert_contains "$out_file" "selected=two"
	assert_contains "$out_file" "$(printf '\033[?1000l')"
	assert_contains "$out_file" "$(printf '\033[?1006l')"
}

run_ansi_menu_mouse_wheel_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; ANSI mouse wheel smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/ansi-menu-mouse-wheel.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'INSTALLER_VERSION=smoke'
		printf 'MENU_LIST=%s\n' "$(shell_quote "$work_dir/menu-mouse-wheel")"
		printf '%s\n' 'stty rows 25 cols 80 2>/dev/null || true'
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'menu_reset'
		printf '%s\n' 'menu_add "one" "First option"'
		printf '%s\n' 'menu_add "two" "Second option"'
		printf '%s\n' 'select_from_menu "Mouse wheel" "option"'
		# shellcheck disable=SC2016
		printf '%s\n' 'printf "selected=%s\n" "$SELECTED_VALUE"'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	( sleep 1; printf '\033[<65;12;8M'; sleep 1; printf '\n' ) |
		OWRT_UI_MODE=ansi TERM=xterm script -q -e -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "ANSI mouse wheel smoke failed"

	assert_contains "$out_file" "selected=two"
}

run_ansi_mouse_disabled_smoke() {
	work_dir="$1"
	out_file="$2"
	linux_out_file="$3"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; ANSI mouse opt-out smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/ansi-mouse-disabled.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'ui_mouse_enable'
		# shellcheck disable=SC2016
		printf '%s\n' 'printf "mouse=%s\n" "$UI_MOUSE_ENABLED"'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	OWRT_UI_MODE=ansi OWRT_UI_NO_MOUSE=1 TERM=xterm \
		script -q -e -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "ANSI mouse opt-out smoke failed"

	assert_contains "$out_file" "mouse=0"
	assert_not_contains "$out_file" "$(printf '\033[?1000h')"
	assert_not_contains "$out_file" "$(printf '\033[?1006h')"

	OWRT_UI_MODE=ansi TERM=linux \
		script -q -e -c "$harness" "$linux_out_file" >/dev/null 2>&1 ||
		fail "ANSI TERM=linux mouse policy smoke failed"

	assert_contains "$linux_out_file" "mouse=0"
	assert_not_contains "$linux_out_file" "$(printf '\033[?1000h')"
	assert_not_contains "$linux_out_file" "$(printf '\033[?1006h')"
}

run_line_form_back_smoke() {
	work_dir="$1"
	out_file="$2"

	printf '!back\n!!back\n' |
		OWRT_UI_MODE=line TERM=dumb sh -eu -c '
			. "$1"
			setup_ui
			prompt_default "Value" "default" "Form back"
			printf "first_action=%s first_value=%s\n" "$UI_INPUT_ACTION" "$SELECTED_INPUT"
			prompt_default "Value" "default" "Literal back"
			printf "second_action=%s second_value=%s\n" "$UI_INPUT_ACTION" "$SELECTED_INPUT"
		' sh "$UI_LIB" > "$out_file" 2>&1

	assert_contains "$out_file" "first_action=back first_value="
	assert_contains "$out_file" "second_action=submit second_value=!back"
}

run_ansi_form_back_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; ANSI form Back smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/ansi-form-back.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'INSTALLER_VERSION=smoke'
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'prompt_default "LAN IPv4" "192.168.1.1/24" "LAN IPv4 settings"'
		# shellcheck disable=SC2016
		printf '%s\n' 'printf "action=%s value=%s\n" "$UI_INPUT_ACTION" "$SELECTED_INPUT"'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	( sleep 1; printf '\033' ) |
		OWRT_UI_MODE=ansi TERM=xterm script -q -e -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "ANSI form Back smoke failed"

	assert_contains "$out_file" "action=back value="
	assert_contains "$out_file" "$(printf '\033[?25h')"
}

run_ansi_form_edit_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; ANSI form editor smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/ansi-form-edit.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'INSTALLER_VERSION=smoke'
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'prompt_default "Value" "default" "Form editor"'
		# shellcheck disable=SC2016
		printf '%s\n' 'printf "action=%s value=%s\n" "$UI_INPUT_ACTION" "$SELECTED_INPUT"'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	# Arrow Up is ignored; both Ctrl-H and DEL remove one character.
	( sleep 1; printf '\033[Aab\010c\177d\n' ) |
		OWRT_UI_MODE=ansi TERM=xterm script -q -e -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "ANSI form editor smoke failed"

	assert_contains "$out_file" "action=submit value=ad"
	assert_not_contains "$out_file" "action=back"
}

run_ansi_secret_form_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; ANSI secret form smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/ansi-secret-form.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'INSTALLER_VERSION=smoke'
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'prompt_secret "PPPoE password" "PPPoE settings"'
		# shellcheck disable=SC2016
		printf '%s\n' 'printf "action=%s length=%s\n" "$UI_INPUT_ACTION" "${#SELECTED_INPUT}"'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	( sleep 1; printf 's3cr3t\n' ) |
		OWRT_UI_MODE=ansi TERM=xterm script -q -e -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "ANSI secret form smoke failed"

	assert_contains "$out_file" "******"
	assert_contains "$out_file" "action=submit length=6"
	assert_not_contains "$out_file" "s3cr3t"
}

run_dialog_form_back_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; dialog form Back smoke skipped.\n'
		return 0
	fi

	fake_bin="$work_dir/dialog-bin"
	mkdir -p "$fake_bin"
	{
		printf '%s\n' '#!/bin/sh'
		# shellcheck disable=SC2016
		printf '%s\n' '[ "${1:-}" = "--version" ] && exit 0'
		printf '%s\n' 'exit 1'
	} > "$fake_bin/dialog"
	chmod +x "$fake_bin/dialog"

	harness="$work_dir/dialog-form-back.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'prompt_default "Value" "default" "Dialog form"'
		# shellcheck disable=SC2016
		printf '%s\n' 'printf "mode=%s action=%s value=%s\n" "$UI_MODE_ACTUAL" "$UI_INPUT_ACTION" "$SELECTED_INPUT"'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	PATH="$fake_bin:$PATH" OWRT_UI_MODE=dialog TERM=xterm \
		script -q -e -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "dialog form Back smoke failed"

	assert_contains "$out_file" "mode=dialog action=back value="
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

run_curses_selection_smoke() {
	work_dir="$1"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; curses selection smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/curses-selection.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'setup_ui'
		# shellcheck disable=SC2016
		printf '%s\n' 'printf "mode=%s command=%s\n" "$UI_MODE_ACTUAL" "$UI_DIALOG_CMD"'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	for scenario in dialog whiptail ansi; do
		fake_bin="$work_dir/curses-$scenario-bin"
		mkdir -p "$fake_bin"
		case "$scenario" in
			dialog)
				dialog_status=0
				whiptail_status=0
				expected="mode=dialog command=dialog"
				;;
			whiptail)
				dialog_status=1
				whiptail_status=0
				expected="mode=whiptail command=whiptail"
				;;
			ansi)
				dialog_status=1
				whiptail_status=1
				expected="mode=ansi command="
				;;
		esac
		for command_name in dialog whiptail; do
			case "$command_name" in
				dialog) command_status="$dialog_status" ;;
				whiptail) command_status="$whiptail_status" ;;
			esac
			{
				printf '%s\n' '#!/bin/sh'
				printf 'exit %s\n' "$command_status"
			} > "$fake_bin/$command_name"
			chmod +x "$fake_bin/$command_name"
		done

		out_file="$work_dir/curses-selection-$scenario.out"
		PATH="$fake_bin:$PATH" OWRT_UI_MODE=curses TERM=xterm \
			script -q -e -c "$harness" "$out_file" >/dev/null 2>&1 ||
			fail "Curses selection smoke failed for $scenario"
		assert_contains "$out_file" "$expected"
	done

	auto_bin="$work_dir/curses-auto-bin"
	mkdir -p "$auto_bin"
	for command_name in dialog whiptail; do
		{
			printf '%s\n' '#!/bin/sh'
			case "$command_name" in
				dialog) printf '%s\n' 'exit 1' ;;
				whiptail) printf '%s\n' 'exit 0' ;;
			esac
		} > "$auto_bin/$command_name"
		chmod +x "$auto_bin/$command_name"
	done

	PATH="$auto_bin:$PATH" OWRT_UI_MODE=auto TERM=linux \
		script -q -e -c "$harness" "$work_dir/auto-linux.out" >/dev/null 2>&1 ||
		fail "Auto Linux-console backend selection smoke failed"
	assert_contains "$work_dir/auto-linux.out" "mode=whiptail command=whiptail"

	PATH="$auto_bin:$PATH" OWRT_UI_MODE=auto TERM=xterm \
		script -q -e -c "$harness" "$work_dir/auto-xterm.out" >/dev/null 2>&1 ||
		fail "Auto xterm backend selection smoke failed"
	assert_contains "$work_dir/auto-xterm.out" "mode=ansi command="
}

run_whiptail_menu_form_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1 || ! command -v whiptail >/dev/null 2>&1; then
		printf 'SKIP: script(1) or whiptail is unavailable; real whiptail smoke skipped.\n'
		return 0
	fi
	if ! script -q -e -c true "$work_dir/whiptail-script-return.out" >/dev/null 2>&1; then
		printf 'SKIP: script(1) has no usable -e support; real whiptail smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/whiptail-menu-form.sh"
	marker="$work_dir/must-not-exist"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf 'MENU_LIST=%s\n' "$(shell_quote "$work_dir/whiptail-menu")"
		printf '%s\n' 'stty rows 25 cols 80 2>/dev/null || true'
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'menu_reset'
		printf '%s\n' 'menu_add "one" "First option"'
		printf 'menu_add "two" %s\n' "$(shell_quote "Second option; touch $marker")"
		printf '%s\n' 'select_from_menu "Pick value" "value"'
		printf '%s\n' 'prompt_default "Address" "192.0.2.2/24" "Static address"'
		# shellcheck disable=SC2016
		printf '%s\n' 'printf "backend=%s command=%s selected=%s input=%s action=%s colors=%s\n" "$UI_MODE_ACTUAL" "$UI_DIALOG_CMD" "$SELECTED_VALUE" "$SELECTED_INPUT" "$UI_INPUT_ACTION" "${NEWT_COLORS:+set}"'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	( sleep 1; printf '\033[B\r'; sleep 1; printf '\025198.51.100.7/24\r'; sleep 1 ) |
		OWRT_UI_MODE=whiptail TERM=xterm script -q -e -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "Real whiptail menu/form smoke failed"

	assert_contains "$out_file" "backend=whiptail command=whiptail selected=two input=198.51.100.7/24 action=submit colors=set"
	[ ! -e "$marker" ] || fail "Whiptail menu label was evaluated by the shell"
}

run_whiptail_back_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1 || ! command -v whiptail >/dev/null 2>&1; then
		printf 'SKIP: script(1) or whiptail is unavailable; whiptail Back smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/whiptail-back.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'prompt_default "Address" "192.0.2.2/24" "Static address"'
		# shellcheck disable=SC2016
		printf '%s\n' 'printf "backend=%s action=%s value=%s\n" "$UI_MODE_ACTUAL" "$UI_INPUT_ACTION" "$SELECTED_INPUT"'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	( sleep 1; printf '\033'; sleep 2 ) |
		OWRT_UI_MODE=whiptail TERM=xterm script -q -e -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "Real whiptail Back smoke failed"

	assert_contains "$out_file" "backend=whiptail action=back value="
}

run_whiptail_secret_smoke() {
	work_dir="$1"
	out_file="$2"

	if ! command -v script >/dev/null 2>&1 || ! command -v whiptail >/dev/null 2>&1; then
		printf 'SKIP: script(1) or whiptail is unavailable; whiptail secret smoke skipped.\n'
		return 0
	fi

	harness="$work_dir/whiptail-secret.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'prompt_secret "PPPoE password" "PPPoE settings"'
		# shellcheck disable=SC2016
		printf '%s\n' 'printf "backend=%s action=%s length=%s\n" "$UI_MODE_ACTUAL" "$UI_INPUT_ACTION" "${#SELECTED_INPUT}"'
		printf '%s\n' 'SELECTED_INPUT=""'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	( sleep 1; printf 's3cr3t\r'; sleep 1 ) |
		OWRT_UI_MODE=whiptail TERM=xterm script -q -e -c "$harness" "$out_file" >/dev/null 2>&1 ||
		fail "Real whiptail secret smoke failed"

	assert_contains "$out_file" "backend=whiptail action=submit length=6"
	assert_not_contains "$out_file" "s3cr3t"
}

run_whiptail_secret_size_smoke() {
	work_dir="$1"

	if ! command -v script >/dev/null 2>&1; then
		printf 'SKIP: script(1) is unavailable; whiptail secret size smoke skipped.\n'
		return 0
	fi

	fake_bin="$work_dir/secret-size-bin"
	mkdir -p "$fake_bin"
	# shellcheck disable=SC2016 # These lines generate the fake command.
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' '[ "${1:-}" = "--version" ] && exit 0'
		printf '%s\n' 'previous=""'
		printf '%s\n' 'current=""'
		printf '%s\n' 'for argument in "$@"; do previous="$current"; current="$argument"; done'
		printf '%s\n' 'printf "passwordbox height=%s width=%s\n" "$previous" "$current" > "$WHIPTAIL_ARGS"'
		printf '%s\n' 'printf "probe-secret\n" >&2'
	} > "$fake_bin/whiptail"
	chmod +x "$fake_bin/whiptail"

	harness="$work_dir/whiptail-secret-size.sh"
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '. %s\n' "$(shell_quote "$UI_LIB")"
		printf '%s\n' 'setup_ui'
		printf '%s\n' 'ui_terminal_size() { UI_WIDTH=86; UI_INNER_WIDTH=82; UI_TERM_COLS=90; UI_HEIGHT=25; }'
		printf '%s\n' 'prompt_secret "Download PPPoE password" "Download PPPoE password" "" "Step 2 of 2.
Input is hidden and used only for this temporary live uplink.
Leave it empty only if your ISP explicitly requires no password."'
		printf '%s\n' 'SELECTED_INPUT=""'
		printf '%s\n' 'ui_leave'
	} > "$harness"
	chmod +x "$harness"

	WHIPTAIL_ARGS="$work_dir/secret-size.args" PATH="$fake_bin:$PATH" \
	OWRT_UI_MODE=whiptail TERM=xterm \
		script -q -e -c "$harness" "$work_dir/secret-size.out" >/dev/null 2>&1 ||
		fail "Whiptail secret size smoke failed"

	assert_contains "$work_dir/secret-size.args" "passwordbox height=12 width=0"
	assert_not_contains "$work_dir/secret-size.args" "height=0"
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
	run_terminal_size_smoke_case "$work_dir" 24 80 tui
	run_terminal_size_smoke_case "$work_dir" 23 80 line
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
run_payload_title_smoke "$work_dir/payload-title.out"
run_line_progress_stream_smoke "$work_dir" "$work_dir/line-progress.out"
run_line_pppoe_wizard_smoke "$work_dir" "$work_dir/line-pppoe-wizard.out"
run_whiptail_progress_stream_smoke "$work_dir" "$work_dir/whiptail-progress.out"
run_line_menu_smoke "$work_dir" "$work_dir/line-menu.out"
run_ansi_stage_smoke "$work_dir" "$log_file" "$work_dir/ansi-stage.out"
run_ansi_menu_snapshot_smoke "$work_dir" "$work_dir/ansi-menu-snapshot.out" "$work_dir/ansi-menu-snapshot.clean"
run_ansi_menu_ctrl_c_smoke "$work_dir" "$work_dir/ansi-menu-ctrl-c.out"
run_ansi_menu_esc_smoke "$work_dir" "$work_dir/ansi-menu-esc.out"
run_ansi_menu_arrow_smoke "$work_dir" "$work_dir/ansi-menu-arrow.out"
run_ansi_menu_mouse_smoke "$work_dir" "$work_dir/ansi-menu-mouse.out"
run_ansi_menu_mouse_wheel_smoke "$work_dir" "$work_dir/ansi-menu-mouse-wheel.out"
run_ansi_mouse_disabled_smoke "$work_dir" "$work_dir/ansi-mouse-disabled.out" \
	"$work_dir/ansi-mouse-linux-console.out"
run_line_form_back_smoke "$work_dir" "$work_dir/line-form-back.out"
run_ansi_form_back_smoke "$work_dir" "$work_dir/ansi-form-back.out"
run_ansi_form_edit_smoke "$work_dir" "$work_dir/ansi-form-edit.out"
run_ansi_secret_form_smoke "$work_dir" "$work_dir/ansi-secret-form.out"
run_dialog_form_back_smoke "$work_dir" "$work_dir/dialog-form-back.out"
run_dialog_mode_smoke "$work_dir" "$work_dir/dialog-mode.out"
run_curses_selection_smoke "$work_dir"
run_whiptail_menu_form_smoke "$work_dir" "$work_dir/whiptail-menu-form.out"
run_whiptail_back_smoke "$work_dir" "$work_dir/whiptail-back.out"
run_whiptail_secret_smoke "$work_dir" "$work_dir/whiptail-secret.out"
run_whiptail_secret_size_smoke "$work_dir"
run_terminal_size_smoke "$work_dir"

printf 'UI smoke tests passed.\n'
