#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/release-candidate-lib.sh
. "$PROJECT_DIR/scripts/release-candidate-lib.sh"

[ "$#" -eq 2 ] || candidate_die "Usage: $0 CANDIDATE_METADATA HARDWARE_REPORT"
METADATA_REL="$1"
REPORT="$2"
case "$METADATA_REL" in
	release/*-candidate.env) ;;
	*) candidate_die "Candidate metadata must be an explicit release/*-candidate.env path" ;;
esac
METADATA="$PROJECT_DIR/$METADATA_REL"
[ -r "$METADATA" ] || candidate_die "Candidate metadata is not readable: $METADATA_REL"
candidate_metadata_validate "$METADATA" ||
	candidate_die "Candidate metadata has invalid, duplicate, unknown, or executable content"

CANDIDATE_VERSION="$(candidate_metadata_value "$METADATA" CANDIDATE_VERSION)"
CANDIDATE_RUNTIME_COMMIT="$(candidate_metadata_value "$METADATA" CANDIDATE_RUNTIME_COMMIT)"
CANDIDATE_ISO_FILE="$(candidate_metadata_value "$METADATA" CANDIDATE_ISO_FILE)"
CANDIDATE_ISO_SHA256="$(candidate_metadata_value "$METADATA" CANDIDATE_ISO_SHA256)"
CANDIDATE_MANIFEST_SHA256="$(candidate_metadata_value "$METADATA" CANDIDATE_MANIFEST_SHA256)"

candidate_validate_release_version "$CANDIDATE_VERSION"
[ "$METADATA_REL" = "release/${CANDIDATE_VERSION}-candidate.env" ] ||
	candidate_die "Candidate metadata filename does not match CANDIDATE_VERSION"
[ "$CANDIDATE_ISO_FILE" = 'output/openwrt-x86-64-installer-hybrid.iso' ] ||
	candidate_die "Candidate ISO path is not the fixed release artifact"
candidate_require_hex CANDIDATE_RUNTIME_COMMIT "$CANDIDATE_RUNTIME_COMMIT" 40
candidate_require_hex CANDIDATE_ISO_SHA256 "$CANDIDATE_ISO_SHA256" 64
candidate_require_hex CANDIDATE_MANIFEST_SHA256 "$CANDIDATE_MANIFEST_SHA256" 64

cd "$PROJECT_DIR"
candidate_assert_metadata_committed "$METADATA_REL"
[ -r "$CANDIDATE_ISO_FILE" ] || candidate_die "Candidate ISO is not readable: $CANDIDATE_ISO_FILE"
[ -r output/manifest.json ] || candidate_die "Candidate manifest is not readable: output/manifest.json"

actual_iso_sha="$(sha256sum "$CANDIDATE_ISO_FILE" | awk '{ print $1 }')"
[ "$actual_iso_sha" = "$CANDIDATE_ISO_SHA256" ] ||
	candidate_die "Candidate ISO SHA-256 mismatch: $actual_iso_sha"
actual_manifest_sha="$(sha256sum output/manifest.json | awk '{ print $1 }')"
[ "$actual_manifest_sha" = "$CANDIDATE_MANIFEST_SHA256" ] ||
	candidate_die "Candidate manifest SHA-256 mismatch: $actual_manifest_sha"

verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/owrt-candidate-verify.XXXXXX")"
trap 'rm -rf "$verify_dir"' EXIT INT TERM HUP
candidate_extract_iso_manifest "$PROJECT_DIR" "$CANDIDATE_ISO_FILE" \
	"$verify_dir/manifest.json"
cmp -s output/manifest.json "$verify_dir/manifest.json" ||
	candidate_die "Manifest embedded in the ISO does not match output/manifest.json"
embedded_manifest_sha="$(sha256sum "$verify_dir/manifest.json" | awk '{ print $1 }')"
[ "$embedded_manifest_sha" = "$CANDIDATE_MANIFEST_SHA256" ] ||
	candidate_die "Embedded manifest SHA-256 mismatch: $embedded_manifest_sha"

manifest_version="$(candidate_manifest_string output/manifest.json installer_version)" ||
	candidate_die "Candidate manifest has no unique installer_version"
[ "$manifest_version" = "$CANDIDATE_VERSION" ] ||
	candidate_die "Candidate manifest version mismatch: ${manifest_version:-missing}"
manifest_commit="$(candidate_manifest_string output/manifest.json build_commit)" ||
	candidate_die "Candidate manifest has no unique build_commit"
manifest_dirty="$(candidate_manifest_boolean output/manifest.json build_dirty)" ||
	candidate_die "Candidate manifest has no valid build_dirty flag"
[ "$manifest_commit" = "$CANDIDATE_RUNTIME_COMMIT" ] ||
	candidate_die "Candidate manifest build_commit mismatch: $manifest_commit"
[ "$manifest_dirty" = false ] ||
	candidate_die "Candidate manifest records a dirty source tree"

git cat-file -e "$CANDIDATE_RUNTIME_COMMIT^{commit}" 2>/dev/null ||
	candidate_die "Candidate runtime commit is unavailable: $CANDIDATE_RUNTIME_COMMIT"
git merge-base --is-ancestor "$CANDIDATE_RUNTIME_COMMIT" HEAD ||
	candidate_die "Candidate runtime commit is not an ancestor of HEAD"
candidate_assert_runtime_unchanged_since "$CANDIDATE_RUNTIME_COMMIT"

"$PROJECT_DIR/scripts/verify-physical-report.sh" "$REPORT"

printf '[owrt-installer] Release gate passed for %s (%s)\n' \
	"$CANDIDATE_VERSION" "$CANDIDATE_ISO_SHA256"
