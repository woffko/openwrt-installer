#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/release-candidate-lib.sh
. "$PROJECT_DIR/scripts/release-candidate-lib.sh"

[ "$#" -eq 1 ] || candidate_die "Usage: $0 VERSION"
VERSION="$1"
ISO_REL='output/openwrt-x86-64-installer-hybrid.iso'
MANIFEST_REL='output/manifest.json'
CHECKSUMS_REL='output/sha256sums.txt'

candidate_validate_release_version "$VERSION"
cd "$PROJECT_DIR"
candidate_assert_repository_clean
candidate_assert_runtime_clean

metadata_rel="release/${VERSION}-candidate.env"
[ ! -e "$metadata_rel" ] ||
	candidate_die "Candidate metadata already exists and is immutable: $metadata_rel"
[ -r "$ISO_REL" ] || candidate_die "Candidate ISO is not readable: $ISO_REL"
[ -r "$MANIFEST_REL" ] || candidate_die "Candidate manifest is not readable: $MANIFEST_REL"
[ -r "$CHECKSUMS_REL" ] || candidate_die "Checksum manifest is not readable: $CHECKSUMS_REL"

installer_version="$(sed -n 's/^INSTALLER_VERSION="\([^"]*\)"/\1/p' \
	files-installer/usr/sbin/owrt-install | head -n 1)"
# shellcheck disable=SC2016 # Match the literal parameter-expansion wrapper in common.sh.
common_version="$(sed -n 's/^INSTALLER_VERSION="${INSTALLER_VERSION:-\([^"]*\)}"/\1/p' \
	scripts/common.sh | head -n 1)"
manifest_version="$(candidate_manifest_string "$MANIFEST_REL" installer_version)" ||
	candidate_die "Candidate manifest has no unique installer_version"
[ "$installer_version" = "$VERSION" ] ||
	candidate_die "owrt-install version is $installer_version, expected $VERSION"
[ "$common_version" = "$VERSION" ] ||
	candidate_die "scripts/common.sh version is $common_version, expected $VERSION"
[ "$manifest_version" = "$VERSION" ] ||
	candidate_die "Candidate manifest version is $manifest_version, expected $VERSION"

runtime_commit="$(git rev-parse --verify 'HEAD^{commit}')"
manifest_commit="$(candidate_manifest_string "$MANIFEST_REL" build_commit)" ||
	candidate_die "Candidate manifest has no unique build_commit"
manifest_dirty="$(candidate_manifest_boolean "$MANIFEST_REL" build_dirty)" ||
	candidate_die "Candidate manifest has no valid build_dirty flag"
candidate_require_hex build_commit "$manifest_commit" 40
[ "$manifest_commit" = "$runtime_commit" ] ||
	candidate_die "Candidate manifest was built from $manifest_commit, expected $runtime_commit"
[ "$manifest_dirty" = false ] ||
	candidate_die "Candidate manifest records a dirty source tree; rebuild from the clean commit"

(cd output && sha256sum -c sha256sums.txt >/dev/null) ||
	candidate_die "output/sha256sums.txt verification failed"

verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/owrt-candidate-freeze.XXXXXX")"
metadata_tmp=""
cleanup() {
	rm -rf "$verify_dir"
	[ -z "$metadata_tmp" ] || rm -f "$metadata_tmp"
}
trap cleanup EXIT INT TERM HUP

candidate_extract_iso_manifest "$PROJECT_DIR" "$ISO_REL" "$verify_dir/manifest.json"
cmp -s "$MANIFEST_REL" "$verify_dir/manifest.json" ||
	candidate_die "Manifest embedded in the ISO does not match output/manifest.json"

iso_sha256="$(sha256sum "$ISO_REL" | awk '{ print $1 }')"
manifest_sha256="$(sha256sum "$MANIFEST_REL" | awk '{ print $1 }')"
candidate_require_hex CANDIDATE_ISO_SHA256 "$iso_sha256" 64
candidate_require_hex CANDIDATE_MANIFEST_SHA256 "$manifest_sha256" 64

metadata_tmp="$(mktemp "release/.${VERSION}-candidate.env.XXXXXX")"
cat > "$metadata_tmp" <<EOF
CANDIDATE_VERSION='$VERSION'
CANDIDATE_RUNTIME_COMMIT='$runtime_commit'
CANDIDATE_ISO_FILE='$ISO_REL'
CANDIDATE_ISO_SHA256='$iso_sha256'
CANDIDATE_MANIFEST_SHA256='$manifest_sha256'
EOF
chmod 0644 "$metadata_tmp"
mv "$metadata_tmp" "$metadata_rel"
metadata_tmp=""

printf '[owrt-installer] Candidate metadata frozen: %s\n' "$metadata_rel"
printf '[owrt-installer] Runtime commit: %s\n' "$runtime_commit"
printf '[owrt-installer] ISO SHA-256: %s\n' "$iso_sha256"
printf '[owrt-installer] Commit the metadata file before accepting a physical report.\n'
