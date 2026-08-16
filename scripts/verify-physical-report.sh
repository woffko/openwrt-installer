#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
REPORT="${1:-}"
EXPECTED_VERSION="$(sed -n 's/^INSTALLER_VERSION="\([^"]*\)"/\1/p' \
	"$PROJECT_DIR/files-installer/usr/sbin/owrt-install" | head -n 1)"

die() {
	printf '[owrt-installer] ERROR: %s\n' "$*" >&2
	exit 1
}

report_value() {
	key="$1"
	awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); value = $0 } END { print value }' "$REPORT"
}

require_value() {
	key="$1"
	expected="$2"
	actual="$(report_value "$key")"
	[ "$actual" = "$expected" ] ||
		die "$key must be '$expected', found '${actual:-missing}'"
}

[ "$#" -eq 1 ] || die "Usage: $0 HARDWARE_REPORT"
[ -r "$REPORT" ] || die "Hardware report is not readable: $REPORT"

require_value report_schema 4
require_value installer_version "$EXPECTED_VERSION"
require_value kernel_mouse_flag yes
require_value kernel_hardware_test_flag yes
require_value mouse_started yes
require_value mouse_stopped yes
require_value dry_run_complete yes
require_value runtime_cleanup yes
require_value pointer_connection usb-wired
require_value manual_pointer_move pass
require_value manual_click pass
require_value manual_keyboard pass
require_value manual_exact_prompt_mouse_stop pass
require_value manual_storage_rescue_navigation pass
require_value manual_sata_compatible_layout_and_boot pass
require_value manual_nvme_compatible_layout_and_boot pass
require_value manual_standard_sysupgrade_two_cycles pass
require_value manual_safe_upgrade_preserves_data pass
require_value manual_rescue_restore pass
require_value manual_pre_erase_power_cycle_no_change pass
require_value physical_flow_result pass

wheel="$(report_value manual_wheel)"
wheel_reason="$(report_value manual_wheel_skip_reason)"
case "$wheel:$wheel_reason" in
	pass:*) ;;
	skipped:no-scrollable-list) ;;
	*) die "manual_wheel must pass, or be skipped only because no scrollable list was available" ;;
esac

pointer_count="$(report_value relative_pointer_count)"
case "$pointer_count" in
	''|*[!0-9]*) die "relative_pointer_count must be a positive integer" ;;
esac
[ "$pointer_count" -ge 1 ] || die "At least one relative pointer is required"

printf '[owrt-installer] Physical wired USB, SATA/NVMe compatible layout, standard/Safe Upgrade, and rescue alpha gate passed: %s\n' "$REPORT"
