#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
METADATA="${OWRT_CANDIDATE_METADATA:-$PROJECT_DIR/release/v1.0-alpha.8-candidate.env}"
REPORT="${1:-}"

die() {
	printf '[owrt-installer] ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$#" -eq 1 ] || die "Usage: $0 HARDWARE_REPORT"
[ -r "$METADATA" ] || die "Candidate metadata is not readable: $METADATA"
# shellcheck source=release/v1.0-alpha.8-candidate.env
. "$METADATA"

[ -n "${CANDIDATE_VERSION:-}" ] || die "Candidate metadata is missing CANDIDATE_VERSION"
[ -n "${CANDIDATE_RUNTIME_COMMIT:-}" ] || die "Candidate metadata is missing CANDIDATE_RUNTIME_COMMIT"
[ -n "${CANDIDATE_ISO_FILE:-}" ] || die "Candidate metadata is missing CANDIDATE_ISO_FILE"
[ -n "${CANDIDATE_ISO_SHA256:-}" ] || die "Candidate metadata is missing CANDIDATE_ISO_SHA256"
[ -n "${CANDIDATE_MANIFEST_SHA256:-}" ] || die "Candidate metadata is missing CANDIDATE_MANIFEST_SHA256"

cd "$PROJECT_DIR"
[ -r "$CANDIDATE_ISO_FILE" ] || die "Candidate ISO is not readable: $CANDIDATE_ISO_FILE"
[ -r output/manifest.json ] || die "Candidate manifest is not readable: output/manifest.json"

actual_iso_sha="$(sha256sum "$CANDIDATE_ISO_FILE" | awk '{ print $1 }')"
[ "$actual_iso_sha" = "$CANDIDATE_ISO_SHA256" ] ||
	die "Candidate ISO SHA-256 mismatch: $actual_iso_sha"
actual_manifest_sha="$(sha256sum output/manifest.json | awk '{ print $1 }')"
[ "$actual_manifest_sha" = "$CANDIDATE_MANIFEST_SHA256" ] ||
	die "Candidate manifest SHA-256 mismatch: $actual_manifest_sha"

manifest_version="$(sed -n 's/^[[:space:]]*"installer_version": "\([^"]*\)",*$/\1/p' \
	output/manifest.json)"
[ "$manifest_version" = "$CANDIDATE_VERSION" ] ||
	die "Candidate manifest version mismatch: ${manifest_version:-missing}"

git cat-file -e "$CANDIDATE_RUNTIME_COMMIT^{commit}" 2>/dev/null ||
	die "Candidate runtime commit is unavailable: $CANDIDATE_RUNTIME_COMMIT"
git merge-base --is-ancestor "$CANDIDATE_RUNTIME_COMMIT" HEAD ||
	die "Candidate runtime commit is not an ancestor of HEAD"

runtime_paths='files-installer files-target iso packages profiles scripts/common.sh scripts/build-installer.sh scripts/build-hybrid-iso.sh scripts/build-mouse-packages.sh scripts/build-target.sh'
# shellcheck disable=SC2086 # This is a fixed, repository-owned path list.
if ! git diff --quiet "$CANDIDATE_RUNTIME_COMMIT"..HEAD -- $runtime_paths; then
	die "Tracked runtime files changed after the frozen candidate commit"
fi
# shellcheck disable=SC2086 # This is a fixed, repository-owned path list.
if ! git diff --quiet -- $runtime_paths || ! git diff --cached --quiet -- $runtime_paths; then
	die "Uncommitted runtime changes invalidate the frozen candidate"
fi

"$PROJECT_DIR/scripts/verify-physical-report.sh" "$REPORT"

printf '[owrt-installer] Release gate passed for %s (%s)\n' \
	"$CANDIDATE_VERSION" "$CANDIDATE_ISO_SHA256"
