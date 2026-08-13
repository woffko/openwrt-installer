#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
REPORTER="$PROJECT_DIR/files-installer/usr/sbin/owrt-hardware-report"
TMPDIR="${TMPDIR:-/tmp}"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	file="$1"
	pattern="$2"
	grep -F "$pattern" "$file" >/dev/null 2>&1 ||
		fail "Expected $file to contain: $pattern"
}

work_dir="$(mktemp -d "$TMPDIR/owrt-hardware-report-smoke.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT INT TERM

mkdir -p \
	"$work_dir/input/event0/device/capabilities" \
	"$work_dir/input/event0/device/id" \
	"$work_dir/proc"
printf '%s\n' 'console=tty1 owrt.mouse=1 owrt.hardware-test=1' > "$work_dir/cmdline"
printf '%s\n' '3' > "$work_dir/input/event0/device/capabilities/rel"
printf '%s\n' '0003' > "$work_dir/input/event0/device/id/bustype"
printf '%s\n' '1234' > "$work_dir/input/event0/device/id/vendor"
printf '%s\n' '5678' > "$work_dir/input/event0/device/id/product"
cat > "$work_dir/installed" <<'EOF'
P:gpm-daemon
V:1.20.7-r3

P:libnewt
V:0.52.24-r2

P:whiptail
V:0.52.24-r2
EOF
cat > "$work_dir/install.log" <<'EOF'
[owrt-installer-mouse] active on /dev/input/event0 with PID 123
[owrt-installer-mouse] stopped
INFO: Dry run complete; no changes were made
EOF
printf '%s\n' '#!/bin/sh' 'INSTALLER_VERSION="v1.0-alpha.8-dev"' > "$work_dir/owrt-install"

report="$work_dir/report.txt"
OWRT_HW_REPORT_NONINTERACTIVE=1 \
OWRT_HW_CMDLINE_FILE="$work_dir/cmdline" \
OWRT_HW_INPUT_CLASS="$work_dir/input" \
OWRT_HW_APK_DB="$work_dir/installed" \
OWRT_HW_INSTALL_LOG="$work_dir/install.log" \
OWRT_HW_INSTALLER_BIN="$work_dir/owrt-install" \
OWRT_HW_PROC_ROOT="$work_dir/proc" \
OWRT_HW_GPM_PID_FILE="$work_dir/missing-gpm.pid" \
OWRT_HW_GPM_SOCKET="$work_dir/missing-gpmctl" \
OWRT_HW_MOUSE_STATE="$work_dir/missing-state" \
	"$REPORTER" "$report" >/dev/null

assert_contains "$report" "report_schema=1"
assert_contains "$report" "installer_version=v1.0-alpha.8-dev"
assert_contains "$report" "kernel_mouse_flag=yes"
assert_contains "$report" "kernel_hardware_test_flag=yes"
assert_contains "$report" "gpm_daemon_version=1.20.7-r3"
assert_contains "$report" "libnewt_version=0.52.24-r2"
assert_contains "$report" "whiptail_version=0.52.24-r2"
assert_contains "$report" "mouse_started=yes"
assert_contains "$report" "mouse_stopped=yes"
assert_contains "$report" "dry_run_complete=yes"
assert_contains "$report" "runtime_cleanup=yes"
assert_contains "$report" "manual_click=skipped"
assert_contains "$report" "relative_pointer_1=event0,bus=0003,vendor=1234,product=5678"
assert_contains "$report" "relative_pointer_count=1"

printf 'Hardware report smoke tests passed.\n'
