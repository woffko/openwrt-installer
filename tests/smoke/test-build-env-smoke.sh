#!/bin/sh

set -eu

TEST_PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
TMPDIR="${TMPDIR:-/tmp}"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

actual_umask="$({
	umask 077
	# shellcheck source=scripts/common.sh
	. "$TEST_PROJECT_DIR/scripts/common.sh"
	umask
})"

[ "$actual_umask" = "0022" ] || fail "expected scripts/common.sh to set umask 0022, got $actual_umask"

work_dir="$(mktemp -d "$TMPDIR/owrt-build-env-smoke.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT INT TERM

# shellcheck source=scripts/common.sh
. "$TEST_PROJECT_DIR/scripts/common.sh"
IMAGEBUILDER_DIR="$work_dir/imagebuilder"
mkdir -p "$IMAGEBUILDER_DIR/staging_dir/host/bin"
touch "$IMAGEBUILDER_DIR/Makefile" "$IMAGEBUILDER_DIR/repositories"
imagebuilder_ready && fail "incomplete ImageBuilder passed readiness check"
touch "$IMAGEBUILDER_DIR/staging_dir/host/bin/apk"
chmod +x "$IMAGEBUILDER_DIR/staging_dir/host/bin/apk"
imagebuilder_ready || fail "complete ImageBuilder failed readiness check"

printf 'Build environment smoke test passed.\n'
