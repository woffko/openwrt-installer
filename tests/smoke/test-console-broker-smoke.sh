#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
BROKER="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-autostart"
TMPDIR="${TMPDIR:-/tmp}"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	file="$1"
	pattern="$2"
	grep -F -- "$pattern" "$file" >/dev/null 2>&1 || {
		printf '%s\n' "--- $file ---" >&2
		sed -n '1,160p' "$file" >&2 || true
		fail "Expected output to contain: $pattern"
	}
}

[ -x "$BROKER" ] || fail "Console broker is not executable"
grep -F 'owrt-installer-autostart tty1' "$PROJECT_DIR/files-installer/etc/inittab" >/dev/null ||
	fail "inittab does not pass the tty1 broker identity"
grep -F 'owrt-installer-autostart ttyS0' "$PROJECT_DIR/files-installer/etc/inittab" >/dev/null ||
	fail "inittab does not pass the ttyS0 broker identity"
suite="$(mktemp -d "$TMPDIR/owrt-console-broker-smoke.XXXXXX")"
trap 'rm -rf "$suite"' EXIT INT TERM HUP

owner_dir="$suite/atomic-owner.lock"
OWRT_INSTALL_BROKER_SOURCE_ONLY=1 OWRT_INSTALL_BROKER_TEST_MODE=1 \
OWRT_INSTALL_BROKER_DIR="$owner_dir" OWRT_INSTALL_BROKER_TTY=ttyS0 \
	sh -eu -c '
		. "$1"
		BROKER_CONSOLE=ttyS0
		broker_claim
		printf "owner=%s state=%s\n" "$(broker_owner_value)" "$(cat "$BROKER_DIR/state")"
	' sh "$BROKER" > "$suite/atomic-first.out" 2>&1 ||
	fail "First broker owner claim failed"
assert_contains "$suite/atomic-first.out" "owner=ttyS0 state=claiming"

OWRT_INSTALL_BROKER_SOURCE_ONLY=1 OWRT_INSTALL_BROKER_TEST_MODE=1 \
OWRT_INSTALL_BROKER_DIR="$owner_dir" OWRT_INSTALL_BROKER_TTY=tty1 \
	sh -eu -c '
		. "$1"
		BROKER_CONSOLE=tty1
		status=0
		broker_claim || status=$?
		printf "second_status=%s owner=%s\n" "$status" "$(broker_owner_value)"
	' sh "$BROKER" > "$suite/atomic-second.out" 2>&1 ||
	fail "Second broker owner harness failed"
assert_contains "$suite/atomic-second.out" "second_status=1 owner=ttyS0"
[ -d "$owner_dir" ] || fail "Owner lock did not persist after owner process exit"

printf 'noise\n' > "$suite/noise.event"
OWRT_INSTALL_BROKER_SOURCE_ONLY=1 OWRT_INSTALL_BROKER_TEST_MODE=1 \
OWRT_INSTALL_BROKER_EVENT_FILE="$suite/noise.event" \
	sh -eu -c '
		. "$1"
		broker_read_line
		status=0
		broker_input_requests_install || status=$?
		printf "noise_status=%s value=%s\n" "$status" "$BROKER_INPUT"
	' sh "$BROKER" > "$suite/noise.out" 2>&1 ||
	fail "Serial-noise broker harness failed"
assert_contains "$suite/noise.out" "noise_status=1 value=noise"

printf '\n' > "$suite/enter.event"
serial_dir="$suite/serial-owner.lock"
OWRT_INSTALL_BROKER_SOURCE_ONLY=1 OWRT_INSTALL_BROKER_TEST_MODE=1 \
OWRT_INSTALL_BROKER_EVENT_FILE="$suite/enter.event" \
OWRT_INSTALL_BROKER_DIR="$serial_dir" OWRT_INSTALL_BROKER_TTY=ttyS0 \
	sh -eu -c '
		. "$1"
		BROKER_CONSOLE=ttyS0
		broker_run_owner() {
			printf "serial_owner=%s\n" "$BROKER_CONSOLE"
			broker_set_state finished
		}
		broker_arbitrate
	' sh "$BROKER" > "$suite/serial-enter.out" 2>&1 ||
	fail "Serial Enter arbitration failed"
assert_contains "$suite/serial-enter.out" "serial_owner=ttyS0"
[ "$(cat "$serial_dir/tty")" = ttyS0 ] || fail "Serial Enter did not own the broker"

vga_dir="$suite/vga-timeout.lock"
OWRT_INSTALL_BROKER_SOURCE_ONLY=1 OWRT_INSTALL_BROKER_TEST_MODE=1 \
OWRT_INSTALL_BROKER_TIMEOUT=0 OWRT_INSTALL_BROKER_DIR="$vga_dir" \
OWRT_INSTALL_BROKER_TTY=tty1 sh -eu -c '
	. "$1"
	BROKER_CONSOLE=tty1
	broker_run_owner() {
		printf "vga_owner=%s\n" "$BROKER_CONSOLE"
		broker_set_state finished
	}
	broker_arbitrate
' sh "$BROKER" > "$suite/vga-timeout.out" 2>&1 ||
	fail "VGA timeout arbitration failed"
assert_contains "$suite/vga-timeout.out" "vga_owner=tty1"
[ "$(cat "$vga_dir/tty")" = tty1 ] || fail "VGA timeout did not own the broker"

OWRT_INSTALL_BROKER_SOURCE_ONLY=1 OWRT_INSTALL_BROKER_TEST_MODE=1 \
OWRT_INSTALL_BROKER_CMDLINE='console=tty1 owrt.console=ttyS0' \
	sh -eu -c '
		. "$1"
		printf "forced=%s\n" "$(broker_forced_console)"
	' sh "$BROKER" > "$suite/forced.out" 2>&1 ||
	fail "Forced-console parser failed"
assert_contains "$suite/forced.out" "forced=ttyS0"

mirror_dir="$suite/mirror-owner.lock"
mkdir -p "$mirror_dir"
printf 'tty1\n' > "$mirror_dir/tty"
printf '%s\n' "$$" > "$mirror_dir/pid"
printf 'finished\n' > "$mirror_dir/state"
printf 'stage one\nstage two\n' > "$suite/mirror.log"
OWRT_INSTALL_BROKER_SOURCE_ONLY=1 OWRT_INSTALL_BROKER_TEST_MODE=1 \
OWRT_INSTALL_BROKER_DIR="$mirror_dir" OWRT_INSTALL_BROKER_TTY=ttyS0 \
OWRT_INSTALL_LOG="$suite/mirror.log" sh -eu -c '
	. "$1"
	BROKER_CONSOLE=ttyS0
	broker_mirror_owner
' sh "$BROKER" > "$suite/mirror.out" 2>&1 ||
	fail "Read-only mirror harness failed"
assert_contains "$suite/mirror.out" "Installer is active on tty1. This console is read-only."
assert_contains "$suite/mirror.out" "stage one"
assert_contains "$suite/mirror.out" "OWRT_INSTALLER_BROKER_LOGIN=ttyS0"

dead_dir="$suite/dead-owner.lock"
mkdir -p "$dead_dir"
printf 'tty1\n' > "$dead_dir/tty"
printf '99999999\n' > "$dead_dir/pid"
printf 'running\n' > "$dead_dir/state"
OWRT_INSTALL_BROKER_SOURCE_ONLY=1 OWRT_INSTALL_BROKER_TEST_MODE=1 \
OWRT_INSTALL_BROKER_DIR="$dead_dir" OWRT_INSTALL_BROKER_TTY=ttyS0 \
	sh -eu -c '
		. "$1"
		BROKER_CONSOLE=ttyS0
		broker_mirror_owner
		status=0
		broker_claim || status=$?
		printf "takeover_status=%s\n" "$status"
	' sh "$BROKER" > "$suite/dead-owner.out" 2>&1 ||
	fail "Dead-owner broker harness failed"
assert_contains "$suite/dead-owner.out" "owner exited unexpectedly"
assert_contains "$suite/dead-owner.out" "takeover_status=1"

printf 'Console broker smoke tests passed.\n'
