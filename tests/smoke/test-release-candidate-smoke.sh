#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
VERIFIER="$PROJECT_DIR/scripts/verify-release-candidate.sh"
TMPDIR="${TMPDIR:-/tmp}"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

work_dir="$(mktemp -d "$TMPDIR/owrt-release-candidate-smoke.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT INT TERM

report="$work_dir/wired-report.txt"
cat > "$report" <<'EOF'
report_schema=2
installer_version=v1.0-alpha.8
kernel_mouse_flag=yes
kernel_hardware_test_flag=yes
mouse_started=yes
mouse_stopped=yes
dry_run_complete=yes
runtime_cleanup=yes
pointer_connection=usb-wired
manual_pointer_move=pass
manual_click=pass
manual_wheel=pass
manual_wheel_skip_reason=not-applicable
manual_keyboard=pass
manual_exact_prompt_mouse_stop=pass
relative_pointer_count=1
physical_flow_result=pass
EOF

"$VERIFIER" "$report" >/dev/null || fail "Release gate rejected a valid candidate fixture"

sed 's/^pointer_connection=usb-wired$/pointer_connection=usb-receiver/' \
	"$report" > "$work_dir/receiver-report.txt"
if "$VERIFIER" "$work_dir/receiver-report.txt" >/dev/null 2>&1; then
	fail "Release gate accepted a USB receiver fixture"
fi

metadata="$work_dir/bad-candidate.env"
sed 's/^CANDIDATE_ISO_SHA256=.*/CANDIDATE_ISO_SHA256='"'"'0000000000000000000000000000000000000000000000000000000000000000'"'"'/' \
	"$PROJECT_DIR/release/v1.0-alpha.8-candidate.env" > "$metadata"
if OWRT_CANDIDATE_METADATA="$metadata" "$VERIFIER" "$report" >/dev/null 2>&1; then
	fail "Release gate accepted a mismatched candidate ISO SHA-256"
fi

printf 'Release candidate gate smoke tests passed.\n'
