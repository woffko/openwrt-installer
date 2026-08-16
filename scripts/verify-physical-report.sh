#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
REPORT="${1:-}"
MANIFEST="${2:-$PROJECT_DIR/output/manifest.json}"
# shellcheck source=scripts/release-candidate-lib.sh
. "$PROJECT_DIR/scripts/release-candidate-lib.sh"
EXPECTED_VERSION="$(sed -n 's/^INSTALLER_VERSION="\([^"]*\)"/\1/p' \
	"$PROJECT_DIR/files-installer/usr/sbin/owrt-install" | head -n 1)"

die() {
	printf '[owrt-installer] ERROR: %s\n' "$*" >&2
	exit 1
}

report_value() {
	key="$1"
	awk -F= -v key="$key" '
		$1 == key { sub(/^[^=]*=/, ""); value = $0; count++ }
		END { if (count != 1) exit 1; print value }
	' "$REPORT"
}

require_value() {
	key="$1"
	expected="$2"
	actual="$(report_value "$key" || true)"
	[ "$actual" = "$expected" ] ||
		die "$key must be '$expected', found '${actual:-missing}'"
}

require_lower_hex() {
	key="$1"
	value="$2"
	expected_length="$3"
	[ "${#value}" -eq "$expected_length" ] ||
		die "$key must contain exactly $expected_length lowercase hexadecimal characters"
	case "$value" in *[!0-9a-f]*) die "$key must contain only lowercase hexadecimal characters" ;; esac
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	die "Usage: $0 HARDWARE_REPORT [MANIFEST]"
fi
[ -r "$REPORT" ] || die "Hardware report is not readable: $REPORT"
[ -r "$MANIFEST" ] || die "Expected artifact manifest is not readable: $MANIFEST"

EXPECTED_MANIFEST_SHA256="$(sha256sum "$MANIFEST" | awk '{ print $1 }')"
EXPECTED_MANIFEST_VERSION="$(candidate_manifest_string "$MANIFEST" installer_version)" ||
	die "Expected artifact manifest has no unique installer_version"
EXPECTED_BUILD_COMMIT="$(candidate_manifest_string "$MANIFEST" build_commit)" ||
	die "Expected artifact manifest has no unique build_commit"
EXPECTED_BUILD_DIRTY="$(candidate_manifest_boolean "$MANIFEST" build_dirty)" ||
	die "Expected artifact manifest has no valid build_dirty"
EXPECTED_PAYLOAD_SHA256="$(candidate_manifest_string "$MANIFEST" payload_sha256)" ||
	die "Expected artifact manifest has no unique payload_sha256"
require_lower_hex artifact_manifest_sha256 "$EXPECTED_MANIFEST_SHA256" 64
require_lower_hex artifact_build_commit "$EXPECTED_BUILD_COMMIT" 40
require_lower_hex artifact_payload_sha256 "$EXPECTED_PAYLOAD_SHA256" 64
[ "$EXPECTED_BUILD_DIRTY" = "false" ] ||
	die "Physical acceptance requires a manifest built from a clean source commit"
[ "$EXPECTED_MANIFEST_VERSION" = "$EXPECTED_VERSION" ] ||
	die "Expected artifact manifest version differs from the current runtime"

require_value report_schema 4
require_value installer_version "$EXPECTED_VERSION"
require_value artifact_manifest_sha256 "$EXPECTED_MANIFEST_SHA256"
require_value artifact_manifest_version "$EXPECTED_MANIFEST_VERSION"
require_value artifact_build_commit "$EXPECTED_BUILD_COMMIT"
require_value artifact_build_dirty false
require_value artifact_payload_sha256 "$EXPECTED_PAYLOAD_SHA256"
require_value artifact_identity_valid yes
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

wheel="$(report_value manual_wheel || true)"
wheel_reason="$(report_value manual_wheel_skip_reason || true)"
case "$wheel:$wheel_reason" in
	pass:*) ;;
	skipped:no-scrollable-list) ;;
	*) die "manual_wheel must pass, or be skipped only because no scrollable list was available" ;;
esac

pointer_count="$(report_value relative_pointer_count || true)"
case "$pointer_count" in
	''|*[!0-9]*) die "relative_pointer_count must be a positive integer" ;;
esac
[ "$pointer_count" -ge 1 ] || die "At least one relative pointer is required"

printf '[owrt-installer] Physical wired USB, SATA/NVMe compatible layout, standard/Safe Upgrade, and rescue alpha gate passed: %s\n' "$REPORT"
