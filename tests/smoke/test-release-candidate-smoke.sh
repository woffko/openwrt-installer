#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
TMPDIR="${TMPDIR:-/tmp}"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

expect_rejected() {
	label="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		fail "$label was accepted"
	fi
}

work_dir="$(mktemp -d "$TMPDIR/owrt-release-candidate-smoke.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT INT TERM HUP
repo="$work_dir/repo"
mkdir -p \
	"$repo/scripts" \
	"$repo/files-installer/usr/sbin" \
	"$repo/files-target" \
	"$repo/iso" \
	"$repo/packages" \
	"$repo/profiles" \
	"$repo/release" \
	"$repo/output" \
	"$repo/build/host-tools/usr/bin"

cp "$PROJECT_DIR/scripts/release-candidate-lib.sh" "$repo/scripts/"
cp "$PROJECT_DIR/scripts/freeze-release-candidate.sh" "$repo/scripts/"
cp "$PROJECT_DIR/scripts/verify-release-candidate.sh" "$repo/scripts/"
cp "$PROJECT_DIR/scripts/verify-physical-report.sh" "$repo/scripts/"
chmod +x "$repo/scripts/"*.sh

cat > "$repo/scripts/common.sh" <<'EOF'
INSTALLER_VERSION="${INSTALLER_VERSION:-v1.0-alpha.9}"
EOF
cat > "$repo/files-installer/usr/sbin/owrt-install" <<'EOF'
#!/bin/sh
INSTALLER_VERSION="v1.0-alpha.9"
EOF
chmod +x "$repo/files-installer/usr/sbin/owrt-install"
printf 'runtime fixture\n' > "$repo/files-target/runtime.txt"
printf 'runtime fixture\n' > "$repo/iso/runtime.txt"
printf 'runtime fixture\n' > "$repo/packages/runtime.txt"
printf 'runtime fixture\n' > "$repo/profiles/runtime.txt"
printf '.PHONY: all\nall:\n\t@true\n' > "$repo/Makefile"
cat > "$repo/.gitignore" <<'EOF'
/build/
/output/
/files-installer/usr/share/owrt-installer/manifest.json
/files-installer/usr/share/owrt-installer/target.img.gz
/files-installer/usr/share/owrt-installer/98-installer-network
/files-installer/usr/share/owrt-installer/storage-guard/
EOF

mkdir -p "$repo/files-installer/usr/share/owrt-installer/storage-guard"
printf 'generated manifest\n' > \
	"$repo/files-installer/usr/share/owrt-installer/manifest.json"
printf 'generated payload\n' > \
	"$repo/files-installer/usr/share/owrt-installer/target.img.gz"
printf 'generated network applier\n' > \
	"$repo/files-installer/usr/share/owrt-installer/98-installer-network"
for generated_guard in \
	install-upgrade-guard \
	owrt-installer-guard.init \
	sysupgrade-wrapper \
	upgrade-guard; do
	printf 'generated guard asset\n' > \
		"$repo/files-installer/usr/share/owrt-installer/storage-guard/$generated_guard"
done

# The fixture xorriso exposes the manifest sidecar associated with its fake ISO.
cat > "$repo/build/host-tools/usr/bin/xorriso" <<'EOF'
#!/bin/sh
set -eu
iso=''
source_path=''
destination=''
while [ "$#" -gt 0 ]; do
	case "$1" in
		-indev)
			iso="$2"
			shift 2
			;;
		-extract)
			source_path="$2"
			destination="$3"
			shift 3
			;;
		*) shift ;;
	esac
done
[ "$source_path" = /manifest.json ]
cp "${iso}.manifest.json" "$destination"
EOF
chmod +x "$repo/build/host-tools/usr/bin/xorriso"

git -C "$repo" init -q
git -C "$repo" config user.name 'OpenWrt Installer Smoke'
git -C "$repo" config user.email 'smoke@example.invalid'
git -C "$repo" add .
git -C "$repo" commit -qm 'runtime fixture'
runtime_commit="$(git -C "$repo" rev-parse 'HEAD^{commit}')"
payload_sha256=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789

write_manifest() {
	version="$1"
	dirty="$2"
	cat > "$repo/output/manifest.json" <<EOF
{
  "installer_version": "$version",
  "build_date": "2026-08-15T00:00:00Z",
  "build_commit": "$runtime_commit",
  "build_dirty": $dirty,
  "openwrt_version": "25.12.5",
  "payload_sha256": "$payload_sha256"
}
EOF
	cp "$repo/output/manifest.json" \
		"$repo/output/openwrt-x86-64-installer-hybrid.iso.manifest.json"
	printf 'fake hybrid ISO for %s\n' "$version" > \
		"$repo/output/openwrt-x86-64-installer-hybrid.iso"
	(
		cd "$repo/output"
		sha256sum openwrt-x86-64-installer-hybrid.iso manifest.json > sha256sums.txt
	)
}

freeze="$repo/scripts/freeze-release-candidate.sh"
verifier="$repo/scripts/verify-release-candidate.sh"
metadata_rel='release/v1.0-alpha.9-candidate.env'
metadata="$repo/$metadata_rel"

write_manifest v1.0-alpha.9 false
printf 'dirty documentation\n' > "$repo/dirty-note.txt"
expect_rejected 'dirty repository freeze' "$freeze" v1.0-alpha.9
rm -f "$repo/dirty-note.txt"
expect_rejected 'development version freeze' "$freeze" v1.0-alpha.9-dev

write_manifest v1.0-alpha.8 false
expect_rejected 'manifest version mismatch freeze' "$freeze" v1.0-alpha.9
write_manifest v1.0-alpha.9 true
expect_rejected 'dirty manifest provenance freeze' "$freeze" v1.0-alpha.9
write_manifest v1.0-alpha.9 false

mv "$repo/output/sha256sums.txt" "$work_dir/sha256sums.txt"
expect_rejected 'missing checksum manifest freeze' "$freeze" v1.0-alpha.9
mv "$work_dir/sha256sums.txt" "$repo/output/sha256sums.txt"
printf 'corrupt checksum manifest\n' > "$repo/output/sha256sums.txt"
expect_rejected 'corrupt checksum manifest freeze' "$freeze" v1.0-alpha.9
write_manifest v1.0-alpha.9 false

(
	cd "$repo"
	"$freeze" v1.0-alpha.9 >/dev/null
) || fail "Freeze rejected a clean, matching candidate fixture"
[ -s "$metadata" ] || fail "Freeze did not create candidate metadata"
cp "$metadata" "$work_dir/good-candidate.env"
git -C "$repo" add "$metadata_rel"
git -C "$repo" commit -qm 'freeze candidate metadata'
expect_rejected 'candidate metadata overwrite' "$freeze" v1.0-alpha.9

report="$work_dir/wired-report.txt"
manifest_sha256="$(sha256sum "$repo/output/manifest.json" | awk '{ print $1 }')"
cat > "$report" <<EOF
report_schema=4
installer_version=v1.0-alpha.9
artifact_manifest_sha256=$manifest_sha256
artifact_manifest_version=v1.0-alpha.9
artifact_build_commit=$runtime_commit
artifact_build_dirty=false
artifact_payload_sha256=$payload_sha256
artifact_identity_valid=yes
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
manual_storage_rescue_navigation=pass
manual_sata_compatible_layout_and_boot=pass
manual_nvme_compatible_layout_and_boot=pass
manual_standard_sysupgrade_two_cycles=pass
manual_safe_upgrade_preserves_data=pass
manual_rescue_restore=pass
manual_pre_erase_power_cycle_no_change=pass
relative_pointer_count=1
physical_flow_result=pass
EOF

(
	cd "$repo"
	"$verifier" "$metadata_rel" "$report" >/dev/null
) || fail "Release gate rejected a valid candidate fixture"

(
	cd "$work_dir"
	"$verifier" "$metadata_rel" "$report" >/dev/null
) || fail "Release gate depends on the caller working directory"

sed 's/^pointer_connection=usb-wired$/pointer_connection=usb-receiver/' \
	"$report" > "$work_dir/receiver-report.txt"
expect_rejected 'USB receiver report' \
	"$verifier" "$metadata_rel" "$work_dir/receiver-report.txt"

printf 'untracked runtime\n' > "$repo/files-installer/untracked-runtime"
expect_rejected 'untracked runtime file' "$verifier" "$metadata_rel" "$report"
rm -f "$repo/files-installer/untracked-runtime"

printf '*.ignored-runtime\n' >> "$repo/.git/info/exclude"
printf 'ignored runtime\n' > "$repo/files-installer/payload.ignored-runtime"
expect_rejected 'unexpected ignored runtime file' "$verifier" "$metadata_rel" "$report"
rm -f "$repo/files-installer/payload.ignored-runtime"

printf 'unexpected generated helper\n' > \
	"$repo/files-installer/usr/share/owrt-installer/storage-guard/unexpected-helper"
expect_rejected 'unexpected ignored storage guard helper' \
	"$verifier" "$metadata_rel" "$report"
rm -f "$repo/files-installer/usr/share/owrt-installer/storage-guard/unexpected-helper"

printf '# tracked change\n' >> "$repo/files-installer/usr/sbin/owrt-install"
expect_rejected 'tracked runtime change' "$verifier" "$metadata_rel" "$report"
git -C "$repo" restore files-installer/usr/sbin/owrt-install

printf '# staged change\n' >> "$repo/files-installer/usr/sbin/owrt-install"
git -C "$repo" add files-installer/usr/sbin/owrt-install
expect_rejected 'staged runtime change' "$verifier" "$metadata_rel" "$report"
git -C "$repo" restore --staged files-installer/usr/sbin/owrt-install
git -C "$repo" restore files-installer/usr/sbin/owrt-install

cp "$repo/output/manifest.json" "$work_dir/embedded-good.json"
sed 's/"openwrt_version": "25.12.5"/"openwrt_version": "0.0.0"/' \
	"$work_dir/embedded-good.json" > \
	"$repo/output/openwrt-x86-64-installer-hybrid.iso.manifest.json"
expect_rejected 'embedded manifest mismatch' "$verifier" "$metadata_rel" "$report"
cp "$work_dir/embedded-good.json" \
	"$repo/output/openwrt-x86-64-installer-hybrid.iso.manifest.json"

sed 's/^CANDIDATE_ISO_SHA256=.*/CANDIDATE_ISO_SHA256='"'"'0000000000000000000000000000000000000000000000000000000000000000'"'"'/' \
	"$work_dir/good-candidate.env" > "$metadata"
git -C "$repo" add "$metadata_rel"
git -C "$repo" commit -qm 'bad candidate hash fixture'
expect_rejected 'mismatched candidate ISO SHA-256' \
	"$verifier" "$metadata_rel" "$report"

injection_marker="$work_dir/metadata-executed"
cp "$work_dir/good-candidate.env" "$metadata"
# shellcheck disable=SC2016 # Literal command substitution proves metadata is never sourced.
printf 'MALICIOUS=$(touch %s)\n' "$injection_marker" >> "$metadata"
git -C "$repo" add "$metadata_rel"
git -C "$repo" commit -qm 'metadata injection fixture'
expect_rejected 'executable metadata content' "$verifier" "$metadata_rel" "$report"
[ ! -e "$injection_marker" ] || fail "Candidate metadata was executed as shell code"

expect_rejected 'implicit historical metadata path' "$verifier" "$report"

printf 'Release candidate freeze and gate smoke tests passed.\n'
