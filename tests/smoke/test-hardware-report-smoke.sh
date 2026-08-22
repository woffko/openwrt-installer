#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
REPORTER="$PROJECT_DIR/files-installer/usr/sbin/owrt-hardware-report"
VERIFIER="$PROJECT_DIR/scripts/verify-physical-report.sh"
TMPDIR="${TMPDIR:-/tmp}"
INSTALLER_VERSION="$(sed -n 's/^INSTALLER_VERSION="\([^"]*\)"/\1/p' \
	"$PROJECT_DIR/files-installer/usr/sbin/owrt-install")"
[ -n "$INSTALLER_VERSION" ] || {
	printf 'ERROR: Could not read current installer version\n' >&2
	exit 1
}

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
manifest="$work_dir/manifest.json"
build_commit=0123456789abcdef0123456789abcdef01234567
payload_sha256=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
cat > "$manifest" <<EOF
{
  "installer_version": "$INSTALLER_VERSION",
  "build_commit": "$build_commit",
  "build_dirty": false,
  "payload_sha256": "$payload_sha256"
}
EOF
manifest_sha256="$(sha256sum "$manifest" | awk '{ print $1 }')"

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
V:1.20.7-r5

P:libnewt
V:0.52.24-r4

P:whiptail
V:0.52.24-r4
EOF
cat > "$work_dir/install.log" <<'EOF'
[owrt-installer-mouse] active on /dev/input/mice with PID 123
[owrt-installer-mouse] stopped
INFO: Dry run complete; no changes were made
EOF
printf '%s\n' '#!/bin/sh' "INSTALLER_VERSION=\"$INSTALLER_VERSION\"" > "$work_dir/owrt-install"

report="$work_dir/report.txt"
OWRT_HW_REPORT_NONINTERACTIVE=1 \
OWRT_HW_CMDLINE_FILE="$work_dir/cmdline" \
OWRT_HW_INPUT_CLASS="$work_dir/input" \
OWRT_HW_APK_DB="$work_dir/installed" \
OWRT_HW_INSTALL_LOG="$work_dir/install.log" \
OWRT_HW_INSTALLER_BIN="$work_dir/owrt-install" \
OWRT_HW_MANIFEST="$manifest" \
OWRT_HW_PROC_ROOT="$work_dir/proc" \
OWRT_HW_GPM_PID_FILE="$work_dir/missing-gpm.pid" \
OWRT_HW_GPM_SOCKET="$work_dir/missing-gpmctl" \
OWRT_HW_MOUSE_STATE="$work_dir/missing-state" \
	OWRT_HW_POINTER_CONNECTION=usb-wired \
	OWRT_HW_MANUAL_MOVE=pass \
	OWRT_HW_MANUAL_CLICK=pass \
	OWRT_HW_MANUAL_WHEEL=pass \
	OWRT_HW_MANUAL_KEYBOARD=pass \
	OWRT_HW_MANUAL_EXACT=pass \
	OWRT_HW_MANUAL_STORAGE_NAVIGATION=pass \
	OWRT_HW_MANUAL_SATA_COMPATIBLE=pass \
	OWRT_HW_MANUAL_NVME_COMPATIBLE=pass \
	OWRT_HW_MANUAL_STANDARD_SYSUPGRADE=pass \
	OWRT_HW_MANUAL_SAFE_UPGRADE=pass \
	OWRT_HW_MANUAL_RESCUE_RESTORE=pass \
	OWRT_HW_MANUAL_POWER_CYCLE=pass \
	"$REPORTER" "$report" >/dev/null

assert_contains "$report" "report_schema=4"
assert_contains "$report" "installer_version=$INSTALLER_VERSION"
assert_contains "$report" "artifact_manifest_sha256=$manifest_sha256"
assert_contains "$report" "artifact_manifest_version=$INSTALLER_VERSION"
assert_contains "$report" "artifact_build_commit=$build_commit"
assert_contains "$report" "artifact_build_dirty=false"
assert_contains "$report" "artifact_payload_sha256=$payload_sha256"
assert_contains "$report" "artifact_identity_valid=yes"
assert_contains "$report" "kernel_mouse_flag=yes"
assert_contains "$report" "kernel_hardware_test_flag=yes"
assert_contains "$report" "gpm_daemon_version=1.20.7-r5"
assert_contains "$report" "libnewt_version=0.52.24-r4"
assert_contains "$report" "whiptail_version=0.52.24-r4"
assert_contains "$report" "mouse_started=yes"
assert_contains "$report" "mouse_stopped=yes"
assert_contains "$report" "dry_run_complete=yes"
assert_contains "$report" "runtime_cleanup=yes"
assert_contains "$report" "pointer_connection=usb-wired"
assert_contains "$report" "manual_click=pass"
assert_contains "$report" "manual_wheel=pass"
assert_contains "$report" "manual_wheel_skip_reason=not-applicable"
assert_contains "$report" "manual_storage_rescue_navigation=pass"
assert_contains "$report" "manual_sata_compatible_layout_and_boot=pass"
assert_contains "$report" "manual_nvme_compatible_layout_and_boot=pass"
assert_contains "$report" "manual_standard_sysupgrade_two_cycles=pass"
assert_contains "$report" "manual_safe_upgrade_preserves_data=pass"
assert_contains "$report" "manual_rescue_restore=pass"
assert_contains "$report" "manual_pre_erase_power_cycle_no_change=pass"
assert_contains "$report" "relative_pointer_1=event0,bus=0003,vendor=1234,product=5678"
assert_contains "$report" "relative_pointer_count=1"
assert_contains "$report" "physical_flow_result=pass"
[ "$(stat -c '%a' "$report")" = "600" ] || fail "Hardware report mode must be 600"

"$VERIFIER" "$report" "$manifest" >/dev/null ||
	fail "Physical report verifier rejected a valid wired USB report"

sed \
	-e 's/^manual_wheel=pass$/manual_wheel=skipped/' \
	-e 's/^manual_wheel_skip_reason=not-applicable$/manual_wheel_skip_reason=no-scrollable-list/' \
	"$report" > "$work_dir/no-wheel-report.txt"
"$VERIFIER" "$work_dir/no-wheel-report.txt" "$manifest" >/dev/null ||
	fail "Physical report verifier rejected the documented no-scrollable-list exception"

sed 's/^pointer_connection=usb-wired$/pointer_connection=usb-receiver/' "$report" > "$work_dir/receiver-report.txt"
if "$VERIFIER" "$work_dir/receiver-report.txt" "$manifest" >/dev/null 2>&1; then
	fail "Physical alpha gate verifier accepted a USB receiver report"
fi

sed 's/^artifact_manifest_sha256=.*/artifact_manifest_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
	"$report" > "$work_dir/wrong-artifact-report.txt"
if "$VERIFIER" "$work_dir/wrong-artifact-report.txt" "$manifest" >/dev/null 2>&1; then
	fail "Physical alpha gate verifier accepted a report from another artifact"
fi

cp "$report" "$work_dir/duplicate-identity-report.txt"
printf 'artifact_build_commit=%s\n' "$build_commit" >> "$work_dir/duplicate-identity-report.txt"
if "$VERIFIER" "$work_dir/duplicate-identity-report.txt" "$manifest" >/dev/null 2>&1; then
	fail "Physical alpha gate verifier accepted a duplicate identity field"
fi

incomplete_report="$work_dir/incomplete-report.txt"
incomplete_status=0
OWRT_HW_REPORT_NONINTERACTIVE=1 \
OWRT_HW_CMDLINE_FILE="$work_dir/cmdline" \
OWRT_HW_INPUT_CLASS="$work_dir/input" \
OWRT_HW_APK_DB="$work_dir/installed" \
OWRT_HW_INSTALL_LOG="$work_dir/install.log" \
OWRT_HW_INSTALLER_BIN="$work_dir/owrt-install" \
OWRT_HW_MANIFEST="$manifest" \
OWRT_HW_PROC_ROOT="$work_dir/proc" \
OWRT_HW_GPM_PID_FILE="$work_dir/missing-gpm.pid" \
OWRT_HW_GPM_SOCKET="$work_dir/missing-gpmctl" \
OWRT_HW_MOUSE_STATE="$work_dir/missing-state" \
	"$REPORTER" "$incomplete_report" >/dev/null || incomplete_status=$?
[ "$incomplete_status" -eq 2 ] || fail "Incomplete report must exit with status 2"
assert_contains "$incomplete_report" "pointer_connection=unknown"
assert_contains "$incomplete_report" "manual_rescue_restore=skipped"
assert_contains "$incomplete_report" "physical_flow_result=incomplete"

printf 'Hardware report smoke tests passed.\n'
