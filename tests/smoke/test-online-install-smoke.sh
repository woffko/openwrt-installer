#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INSTALLER="$PROJECT_DIR/files-installer/usr/sbin/owrt-install"
UI_LIB="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-ui"
GRUB_CONFIG="$PROJECT_DIR/iso/boot/grub/grub.cfg"
AUTOSTART="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-autostart"
RELEASE_KEY="$PROJECT_DIR/files-installer/usr/share/owrt-installer/keys/openwrt-release.usign.pub"
TMPDIR="${TMPDIR:-/tmp}"

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	file="$1"
	pattern="$2"
	if ! grep -F -- "$pattern" "$file" >/dev/null 2>&1; then
		printf '%s\n' "--- $file ---" >&2
		sed -n '1,200p' "$file" >&2 || true
		fail "Expected output to contain: $pattern"
	fi
}

assert_not_contains() {
	file="$1"
	pattern="$2"
	if grep -F -- "$pattern" "$file" >/dev/null 2>&1; then
		printf '%s\n' "--- $file ---" >&2
		sed -n '1,200p' "$file" >&2 || true
		fail "Output must not contain: $pattern"
	fi
}

run_netinstall_umask_smoke() {
	case_dir="$1"
	case_output="$case_dir/netinstall-umask.out"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 UI_LIB="$UI_LIB" TMPDIR="$case_dir" \
		sh -eu -c '
			. "$1"
			initial_umask="$(umask)"
			init_netinstall_workdir
			test "$(umask)" = "$initial_umask"
			test "$(stat -c %a "$NETINSTALL_WORKDIR")" = 700
			printf "umask=%s workdir_mode=%s\n" \
				"$(umask)" "$(stat -c %a "$NETINSTALL_WORKDIR")"
			cleanup
		' sh "$INSTALLER" > "$case_output" 2>&1 ||
		fail "netinstall workdir umask smoke failed"

	assert_contains "$case_output" "workdir_mode=700"
}

run_netinstall_pppoe_smoke() {
	case_dir="$1"
	case_output="$case_dir/netinstall-pppoe.out"
	marker_file="$case_dir/netinstall-pppoe.markers"

	printf '%s\n' \
		'download-user@example.net' \
		'!back' \
		'' \
		'download-secret' |
		OWRT_INSTALL_TEST_SOURCE_ONLY=1 UI_LIB="$UI_LIB" OWRT_UI_MODE=line TERM=dumb \
		TMPDIR="$case_dir" sh -eu -c '
			. "$1"
			marker_file="$2"
			autostart_serial_marker() { printf "%s\n" "$1" >> "$marker_file"; }
			AUTO_STARTED=1
			setup_ui
			select_netinstall_pppoe
			printf "result user=%s password_length=%s\n" \
				"$NETINSTALL_PPP_USERNAME" "${#NETINSTALL_PPP_PASSWORD}"
			NETINSTALL_PPP_PASSWORD=""
			cleanup
		' sh "$INSTALLER" "$marker_file" > "$case_output" 2>&1 ||
		fail "download PPPoE wizard smoke failed"

	assert_contains "$case_output" "Download PPPoE username"
	assert_contains "$case_output" "Download PPPoE password"
	assert_contains "$case_output" \
		"result user=download-user@example.net password_length=15"
	assert_not_contains "$case_output" "download-secret"
	[ "$(sed -n '1p' "$marker_file")" = "OWRT_INSTALLER_UI_READY=online-pppoe-username" ] ||
		fail "download PPPoE username marker is missing"
	[ "$(sed -n '2p' "$marker_file")" = "OWRT_INSTALLER_UI_READY=online-pppoe-password" ] ||
		fail "download PPPoE password marker is missing"
	[ "$(sed -n '3p' "$marker_file")" = "OWRT_INSTALLER_UI_READY=online-pppoe-username" ] ||
		fail "Back from download PPPoE password did not return to username"
	[ "$(sed -n '4p' "$marker_file")" = "OWRT_INSTALLER_UI_READY=online-pppoe-password" ] ||
		fail "download PPPoE password was not reopened"
	[ "$(wc -l < "$marker_file" | tr -d ' ')" = "4" ] ||
		fail "download PPPoE wizard emitted unexpected UI markers"
}

run_auto_dhcp_smoke() {
	case_dir="$1"
	auto_output="$case_dir/auto-dhcp.out"
	prepare_output="$case_dir/prepare-auto-dhcp.out"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 UI_LIB="$UI_LIB" TMPDIR="$case_dir" \
		sh -eu -c '
			. "$1"
			INSTALL_LOG="$2/auto-dhcp.log"
			refresh_nics() {
				printf "%s\n" "eth0|00:11:22:33:44:50" "eth1|00:11:22:33:44:51" > "$NIC_LIST"
			}
			get_nic_link() { [ "$1" = eth1 ] && printf up || printf down; }
			ip() { :; }
			ui_install_stage() { printf "stage=%s dev=%s\n" "$1" "$NETINSTALL_DEV"; }
			apply_netinstall_network() {
				printf "apply=%s proto=%s wait=%s\n" "$NETINSTALL_DEV" "$NETINSTALL_PROTO" "$1"
				[ "$NETINSTALL_DEV" = eth1 ]
			}
			restore_netinstall_network() { printf "unexpected-restore\n"; }
			autostart_serial_marker() { printf "marker=%s\n" "$1"; }
			auto_configure_netinstall_dhcp
			printf "selected=%s proto=%s attempted=%s\n" \
				"$NETINSTALL_DEV" "$NETINSTALL_PROTO" "$NETINSTALL_AUTO_DHCP_ATTEMPTED"
			cleanup
		' sh "$INSTALLER" "$case_dir" > "$auto_output" 2>&1 ||
		fail "automatic DHCP selection smoke failed"

	assert_contains "$auto_output" "stage=Automatic DHCP dev=eth1"
	assert_contains "$auto_output" "apply=eth1 proto=dhcp wait=12"
	assert_contains "$auto_output" "marker=OWRT_INSTALLER_NETINSTALL_AUTO_DHCP=eth1"
	assert_contains "$auto_output" "selected=eth1 proto=dhcp attempted=1"
	assert_not_contains "$auto_output" "apply=eth0"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 UI_LIB="$UI_LIB" TMPDIR="$case_dir" \
		sh -eu -c '
			. "$1"
			INSTALL_LOG="$2/prepare-auto-dhcp.log"
			NETINSTALL_WORKDIR="$2/prepare-work"
			mkdir -p "$NETINSTALL_WORKDIR"
			trace=""
			netinstall_has_default_route() { return 1; }
			auto_configure_netinstall_dhcp() {
				trace="${trace}${trace:+,}auto"
				NETINSTALL_AUTO_DHCP_ATTEMPTED=1
				return 0
			}
			acquire_downloaded_payload() {
				trace="${trace}${trace:+,}acquire"
				PAYLOAD_VERSION=25.12.5
				PAYLOAD_BOOT_MODE=UEFI
				return 0
			}
			restore_netinstall_network() { trace="${trace}${trace:+,}restore"; }
			ui_notice() { :; }
			prepare_online_payload
			printf "trace=%s attempted=%s\n" "$trace" "$NETINSTALL_AUTO_DHCP_ATTEMPTED"
			cleanup
		' sh "$INSTALLER" "$case_dir" > "$prepare_output" 2>&1 ||
		fail "online payload automatic DHCP bootstrap smoke failed"

	assert_contains "$prepare_output" "trace=auto,acquire,restore attempted=1"
}

run_latest_check_case() {
	case_dir="$1"
	case_name="$2"
	expected="$3"
	case_output="$case_dir/latest-$case_name.out"

	OWRT_LATEST_TEST_CASE="$case_name" \
	OWRT_INSTALL_TEST_SOURCE_ONLY=1 UI_LIB="$UI_LIB" TMPDIR="$case_dir" \
		sh -eu -c '
			. "$1"
			INSTALL_LOG="$2/latest-$OWRT_LATEST_TEST_CASE.log"
			NETINSTALL_WORKDIR="$2/latest-$OWRT_LATEST_TEST_CASE"
			mkdir -p "$NETINSTALL_WORKDIR"
			trace=""
			trace_add() { trace="${trace}${trace:+,}$1"; }
			json_value() { [ "$1" = openwrt_version ] && printf 25.12.5; }
			netinstall_has_default_route() {
				[ "$OWRT_LATEST_TEST_CASE" != no-network ]
			}
			auto_configure_netinstall_dhcp() {
				trace_add auto
				NETINSTALL_AUTO_DHCP_ATTEMPTED=1
				NETINSTALL_ERROR="no DHCP route"
				return 1
			}
			netinstall_stable_version() {
				trace_add stable
				case "$OWRT_LATEST_TEST_CASE" in
					current) NETINSTALL_STABLE_VERSION=25.12.5 ;;
					*) NETINSTALL_STABLE_VERSION=25.12.6 ;;
				esac
			}
			restore_netinstall_network() { trace_add restore; }
			reset_to_embedded_payload() { trace_add local; }
			menu_reset() { :; }
			menu_note() { :; }
			menu_add() { :; }
			select_from_menu() {
				trace_add menu
				case "$OWRT_LATEST_TEST_CASE" in
					newer-download) SELECTED_VALUE=download ;;
					*) SELECTED_VALUE=embedded ;;
				esac
			}
			prepare_online_payload() { trace_add download; }
			autostart_serial_marker() { trace_add "marker:$1"; }
			check_for_newer_payload
			printf "trace=%s\n" "$trace"
			cleanup
		' sh "$INSTALLER" "$case_dir" > "$case_output" 2>&1 ||
		fail "latest-check case failed: $case_name"

	assert_contains "$case_output" "$expected"
}

run_latest_check_smoke() {
	case_dir="$1"
	version_output="$case_dir/version-compare.out"
	OWRT_INSTALL_TEST_SOURCE_ONLY=1 UI_LIB="$UI_LIB" TMPDIR="$case_dir" \
		sh -eu -c '
			. "$1"
			release_version_is_newer 25.12.6 25.12.5
			! release_version_is_newer 25.12.5 25.12.5
			! release_version_is_newer 25.12.4 25.12.5
			! release_version_is_newer 25.11.99 25.12.5
			printf "version-compare=pass\n"
			cleanup
		' sh "$INSTALLER" > "$version_output" 2>&1 ||
		fail "latest release version comparison smoke failed"
	assert_contains "$version_output" "version-compare=pass"

	run_latest_check_case "$case_dir" no-network \
		"trace=auto,marker:OWRT_INSTALLER_LATEST_CHECK=local-no-network,local"
	run_latest_check_case "$case_dir" current \
		"trace=stable,marker:OWRT_INSTALLER_LATEST_CHECK=local-current,restore,local"
	run_latest_check_case "$case_dir" newer-local \
		"trace=stable,menu,marker:OWRT_INSTALLER_LATEST_CHECK=local-selected,restore,local"
	run_latest_check_case "$case_dir" newer-download \
		"trace=stable,menu,marker:OWRT_INSTALLER_LATEST_CHECK=download-accepted,download"
}

write_fake_curl() {
	path="$1"
	# shellcheck disable=SC2016 # This writes the fake command, not this test's variables.
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'set -eu'
		printf '%s\n' 'output=""; dump_header=""; head_only=0; url=""'
		printf '%s\n' 'while [ "$#" -gt 0 ]; do'
		printf '%s\n' '  case "$1" in'
		printf '%s\n' '    --output|--dump-header|--connect-timeout|--max-time|--max-filesize|--proto)'
		printf '%s\n' '      option=$1; value=$2; shift 2'
		printf '%s\n' '      case "$option" in --output) output=$value ;; --dump-header) dump_header=$value ;; esac'
		printf '%s\n' '      ;;'
		printf '%s\n' '    --head) head_only=1; shift ;;'
		printf '%s\n' '    --fail|--silent|--show-error|--tlsv1.2) shift ;;'
		printf '%s\n' '    *) url=$1; shift ;;'
		printf '%s\n' '  esac'
		printf '%s\n' 'done'
		printf '%s\n' '[ "${FAKE_CURL_FAIL:-0}" != 1 ] || exit 22'
		printf '%s\n' 'if [ "$head_only" = 1 ]; then'
		printf '%s\n' '  size=$(wc -c < "$FAKE_PAYLOAD_PATH" | tr -d " ")'
		printf '%s\n' '  printf "HTTP/2 200\r\ncontent-length: %s\r\n\r\n" "$size" > "$dump_header"'
		printf '%s\n' '  exit 0'
		printf '%s\n' 'fi'
		printf '%s\n' 'case "$url" in'
		printf '%s\n' '  */.versions.json) printf "{\"stable_version\":\"%s\"}\n" "$FAKE_STABLE_VERSION" > "$output" ;;'
		printf '%s\n' '  */sha256sums.sig) printf "fake signature\n" > "$output" ;;'
		printf '%s\n' '  */sha256sums)'
		printf '%s\n' '    hash=$FAKE_PAYLOAD_SHA'
		printf '%s\n' '    [ "${FAKE_BAD_CHECKSUM:-0}" != 1 ] || hash=0000000000000000000000000000000000000000000000000000000000000000'
		printf '%s\n' '    printf "%s *%s\n" "$hash" "$FAKE_EXPECTED_FILENAME" > "$output"'
		printf '%s\n' '    ;;'
		printf '%s\n' '  *.img.gz) cp "$FAKE_PAYLOAD_PATH" "$output" ;;'
		printf '%s\n' '  *) exit 22 ;;'
		printf '%s\n' 'esac'
	} > "$path"
	chmod +x "$path"
}

write_fake_usign() {
	path="$1"
	# shellcheck disable=SC2016 # This writes the fake command.
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' '[ "${FAKE_USIGN_FAIL:-0}" != 1 ]'
	} > "$path"
	chmod +x "$path"
}

write_fake_fdisk() {
	path="$1"
	# shellcheck disable=SC2016 # This writes the fake command.
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'if [ "${FAKE_BAD_LAYOUT:-0}" = 1 ]; then printf "Disklabel type: unknown\n"; exit 0; fi'
		printf '%s\n' 'image=""; for arg do image=$arg; done; case "$image" in *[0-9]) part="${image}p" ;; *) part="$image" ;; esac'
		printf '%s\n' 'case "$OWRT_NETINSTALL_TEST_BOOT_MODE" in'
		printf '%s\n' '  uefi)'
		printf '%s\n' '    printf "Disklabel type: gpt\nDevice Start End Sectors Size Type\n%s1 512 2047 1536 768K Linux filesystem\n%s2 2048 16383 14336 7M Linux filesystem\n" "$part" "$part"'
		printf '%s\n' '    ;;'
		printf '%s\n' '  bios)'
		printf '%s\n' '    printf "Disklabel type: dos\nDevice Start End Sectors Size Id Type\n%s1 512 2047 1536 768K 83 Linux\n%s2 2048 16383 14336 7M 83 Linux\n" "$part" "$part"'
		printf '%s\n' '    ;;'
		printf '%s\n' 'esac'
	} > "$path"
	chmod +x "$path"
}

run_acquire_case() {
	case_name="$1"
	boot_mode="$2"
	expected_status="$3"
	expected_text="$4"
	shift 4
	case_dir="$work_dir/$case_name"
	mkdir -p "$case_dir"
	case_output="$case_dir/output.txt"
	case_filename="openwrt-99.88.7-x86-64-generic-ext4-combined.img.gz"
	[ "$boot_mode" != "uefi" ] ||
		case_filename="openwrt-99.88.7-x86-64-generic-ext4-combined-efi.img.gz"

	set +e
	# shellcheck disable=SC2016 # Variables in this script belong to the child shell.
	env PATH="$fake_bin:$PATH" \
		TMPDIR="$case_dir" UI_LIB="$UI_LIB" \
		OWRT_INSTALL_TEST_SOURCE_ONLY=1 \
		OWRT_NETINSTALL_TEST_MODE=1 \
		OWRT_NETINSTALL_TEST_BOOT_MODE="$boot_mode" \
		OWRT_NETINSTALL_TEST_MEM_AVAILABLE="${TEST_MEM_AVAILABLE:-104857600}" \
		OWRT_NETINSTALL_TEST_RAM_RESERVE=1 \
		FAKE_STABLE_VERSION="${FAKE_STABLE_VERSION:-99.88.7}" \
		FAKE_EXPECTED_FILENAME="$case_filename" \
		FAKE_PAYLOAD_PATH="${FAKE_PAYLOAD_PATH:-$valid_payload}" \
		FAKE_PAYLOAD_SHA="${FAKE_PAYLOAD_SHA:-$valid_payload_sha}" \
		FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
		FAKE_USIGN_FAIL="${FAKE_USIGN_FAIL:-0}" \
		FAKE_BAD_CHECKSUM="${FAKE_BAD_CHECKSUM:-0}" \
		FAKE_BAD_LAYOUT="${FAKE_BAD_LAYOUT:-0}" \
		sh -eu -c '
			. "$1"
			INSTALL_LOG="$2/install.log"
			OPENWRT_RELEASE_KEY="$3"
			ui_install_stage() { :; }
			autostart_serial_marker() { :; }
			status=0
			acquire_downloaded_payload || status=$?
			printf "status=%s\n" "$status"
			printf "error=%s\n" "$NETINSTALL_ERROR"
			if [ "$status" -eq 0 ]; then
				verify_payload
				ui_set_payload_version "$PAYLOAD_VERSION"
				printf "source=%s\n" "$PAYLOAD_SOURCE_ID"
				printf "version=%s\n" "$PAYLOAD_VERSION"
				printf "title=%s\n" "$UI_BACKTITLE"
				printf "boot=%s\n" "$PAYLOAD_BOOT_MODE"
				printf "filename=%s\n" "$PAYLOAD_FILENAME"
				printf "verified_sha=%s\n" "$PAYLOAD_SHA256"
			fi
			cleanup
			exit "$status"
		' sh "$INSTALLER" "$case_dir" "$RELEASE_KEY" > "$case_output" 2>&1
	case_status=$?
	set -e
	[ "$case_status" -eq "$expected_status" ] || {
		cat "$case_output" >&2
		fail "$case_name exited with $case_status instead of $expected_status"
	}
	assert_contains "$case_output" "$expected_text"
	if [ "$expected_status" -eq 0 ]; then
		assert_contains "$case_output" \
			"title=OpenWrt Hellforge Installer | OpenWrt 99.88.7"
	fi
}

assert_contains "$GRUB_CONFIG" 'menuentry "OpenWrt x86 Installer"'
assert_contains "$GRUB_CONFIG" 'owrt.check-latest=1'
assert_contains "$AUTOSTART" 'exec /usr/sbin/owrt-install --autostart --check-latest'
assert_contains "$AUTOSTART" 'exec /usr/sbin/owrt-install --autostart --download-latest'
assert_contains "$UI_LIB" '"New OpenWrt release available") ui_ready_name="online-update"'
assert_contains "$PROJECT_DIR/profiles/packages-installer.txt" 'curl'
assert_contains "$PROJECT_DIR/profiles/packages-installer.txt" 'usign'
assert_contains "$PROJECT_DIR/scripts/build-installer.sh" '98-installer-network'
[ "$(sha256sum "$RELEASE_KEY" | awk '{ print $1 }')" = "d7ac10f9ed1b38033855f3d27c9327d558444fca804c685b17d9dcfb0648228f" ] ||
	fail "Pinned OpenWrt release key hash changed"

work_dir="$(mktemp -d "$TMPDIR/owrt-online-install-smoke.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT INT TERM
fake_bin="$work_dir/bin"
mkdir -p "$fake_bin"
write_fake_curl "$fake_bin/curl"
write_fake_usign "$fake_bin/usign"
write_fake_fdisk "$fake_bin/fdisk"
run_netinstall_umask_smoke "$work_dir"
run_netinstall_pppoe_smoke "$work_dir"
run_auto_dhcp_smoke "$work_dir"
run_latest_check_smoke "$work_dir"

raw_image="$work_dir/image.raw"
valid_payload="$work_dir/image.img.gz"
invalid_payload="$work_dir/not-gzip.img.gz"
dd if=/dev/zero of="$raw_image" bs=1M count=9 status=none
# Minimal ext4 superblock for a 7 MiB root at sector 2048.
printf '\000\034\000\000' | dd of="$raw_image" bs=1 seek=1049604 conv=notrunc status=none
printf '\000\000\000\000' | dd of="$raw_image" bs=1 seek=1049624 conv=notrunc status=none
printf '\123\357' | dd of="$raw_image" bs=1 seek=1049656 conv=notrunc status=none
gzip -c "$raw_image" > "$valid_payload"
printf 'not a gzip stream\n' > "$invalid_payload"
valid_payload_sha="$(sha256sum "$valid_payload" | awk '{ print $1 }')"
invalid_payload_sha="$(sha256sum "$invalid_payload" | awk '{ print $1 }')"

run_acquire_case bios-pass bios 0 'filename=openwrt-99.88.7-x86-64-generic-ext4-combined.img.gz'
run_acquire_case uefi-pass uefi 0 'filename=openwrt-99.88.7-x86-64-generic-ext4-combined-efi.img.gz'

FAKE_STABLE_VERSION=snapshot run_acquire_case invalid-version bios 1 'invalid stable version'
FAKE_CURL_FAIL=1 run_acquire_case https-failure bios 1 'Could not reach the official OpenWrt release index over HTTPS'
FAKE_USIGN_FAIL=1 run_acquire_case bad-signature bios 1 'manifest signature is invalid'
FAKE_BAD_CHECKSUM=1 run_acquire_case checksum-mismatch bios 1 'SHA-256 does not match the signed manifest'
FAKE_PAYLOAD_PATH="$invalid_payload" FAKE_PAYLOAD_SHA="$invalid_payload_sha" \
	run_acquire_case truncated-gzip bios 1 'invalid or truncated gzip stream'
FAKE_BAD_LAYOUT=1 run_acquire_case wrong-layout uefi 1 'unsupported partition table'
TEST_MEM_AVAILABLE=1 run_acquire_case insufficient-ram bios 1 'Insufficient RAM'

fallback_output="$work_dir/fallback.txt"
fallback_manifest="$work_dir/fallback-manifest.json"
cat > "$fallback_manifest" <<EOF_FALLBACK_MANIFEST
{
  "openwrt_version": "25.12.4",
  "image_type": "ext4-combined-efi",
  "payload_source": "embedded",
  "payload_filename": "target.img.gz",
  "payload_sha256": "$valid_payload_sha",
  "payload_uncompressed_size": "9437184"
}
EOF_FALLBACK_MANIFEST
# shellcheck disable=SC2016 # Variables in this script belong to the child shell.
OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$work_dir" UI_LIB="$UI_LIB" sh -eu -c '
	. "$1"
	INSTALL_LOG="$2/fallback.log"
	EMBEDDED_PAYLOAD="$3"
	EMBEDDED_MANIFEST="$4"
	acquire_downloaded_payload() { NETINSTALL_ERROR="forced offline"; return 1; }
	ui_install_stage() { :; }
	ui_notice() { :; }
	netinstall_has_default_route() { return 0; }
	select_from_menu() { SELECTED_VALUE=embedded; }
	autostart_serial_marker() { [ "$1" = "OWRT_INSTALLER_NETINSTALL_FALLBACK=embedded" ]; }
	storage_inspect_payload_layout() {
		STORAGE_TABLE_TYPE=gpt
		STORAGE_PAYLOAD_SECTOR_SIZE=512
		STORAGE_ROOT_START_SECTOR=2048
		STORAGE_ROOT_IMAGE_END_SECTOR=16383
		STORAGE_ROOT_IMAGE_SECTORS=14336
		STORAGE_ROOT_IMAGE_MIB=7
	}
	prepare_online_payload
	verify_payload
	ui_set_payload_version "$PAYLOAD_VERSION"
	printf "source=%s\n" "$PAYLOAD_SOURCE_ID"
	printf "payload=%s\n" "$PAYLOAD"
	printf "title=%s\n" "$UI_BACKTITLE"
	cleanup
' sh "$INSTALLER" "$work_dir" "$valid_payload" "$fallback_manifest" > "$fallback_output" 2>&1
assert_contains "$fallback_output" 'source=embedded'
assert_contains "$fallback_output" "payload=$valid_payload"
assert_contains "$fallback_output" \
	'title=OpenWrt Hellforge Installer | OpenWrt 25.12.4'

printf '%s\n' "Online install smoke tests passed."
