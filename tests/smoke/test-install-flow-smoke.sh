#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INSTALLER="$PROJECT_DIR/files-installer/usr/sbin/owrt-install"
UI_LIB="$PROJECT_DIR/files-installer/usr/libexec/owrt-installer-ui"
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

assert_no_fifo() {
	path="$1"
	if find "$path" -type p -print -quit | grep . >/dev/null 2>&1; then
		find "$path" -type p -print >&2
		fail "Named progress pipes were not cleaned up under $path"
	fi
}

write_fake_pv() {
	path="$1"
	# shellcheck disable=SC2016
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' '(printf "0\n" >&2; sleep 1; printf "50\n" >&2; sleep 1; printf "100\n" >&2) &'
		printf '%s\n' 'progress_pid=$!'
		printf '%s\n' 'copy_status=0'
		printf '%s\n' 'cat || copy_status=$?'
		printf '%s\n' 'wait "$progress_pid" || true'
		printf '%s\n' 'exit "$copy_status"'
	} > "$path"
	chmod +x "$path"
}

run_payload_progress_smoke() {
	work_dir="$1/payload-progress"
	mkdir -p "$work_dir/bin"
	raw_file="$work_dir/payload.raw"
	payload_file="$work_dir/payload.raw.gz"
	target_file="$work_dir/target.raw"
	out_file="$work_dir/run.out"
	progress_file="$work_dir/progress.out"

	dd if=/dev/zero of="$raw_file" bs=1024 count=128 >/dev/null 2>&1
	printf 'openwrt-installer-progress-smoke\n' | dd of="$raw_file" conv=notrunc >/dev/null 2>&1
	gzip -c "$raw_file" > "$payload_file"
	payload_size="$(wc -c < "$raw_file" | tr -d ' ')"
	write_fake_pv "$work_dir/bin/pv"

	PATH="$work_dir/bin:$PATH" OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$work_dir" \
		UI_LIB="$UI_LIB" sh -eu -c '
			. "$1"
			PAYLOAD="$2"
			PAYLOAD_UNCOMPRESSED_SIZE="$3"
			INSTALL_LOG="$4/install.log"
			progress_file="$5"
			ui_install_progress_stream() {
				while IFS= read -r percent; do
					printf "progress=%s\n" "$percent" >> "$progress_file"
				done < "$1"
			}
			write_payload_with_percent "$6"
			cleanup
		' sh "$INSTALLER" "$payload_file" "$payload_size" "$work_dir" "$progress_file" "$target_file" \
		> "$out_file" 2>&1

	cmp "$raw_file" "$target_file" || fail "Determinate payload write changed the byte stream"
	assert_contains "$progress_file" "progress=0"
	assert_contains "$progress_file" "progress=50"
	assert_contains "$progress_file" "progress=100"
	assert_no_fifo "$work_dir"
}

run_payload_progress_failure_smoke() {
	work_dir="$1/payload-progress-failure"
	mkdir -p "$work_dir/bin"
	raw_file="$work_dir/payload.raw"
	payload_file="$work_dir/payload.raw.gz"
	out_file="$work_dir/run.out"

	dd if=/dev/zero of="$raw_file" bs=1024 count=128 >/dev/null 2>&1
	gzip -c "$raw_file" > "$payload_file"
	payload_size="$(wc -c < "$raw_file" | tr -d ' ')"
	write_fake_pv "$work_dir/bin/pv"
	# Open the input FIFO like real dd before returning the controlled failure.
	# shellcheck disable=SC2016
	{
		printf '%s\n' '#!/bin/sh'
		printf '%s\n' 'input=""'
		printf '%s\n' 'for arg in "$@"; do case "$arg" in if=*) input=${arg#if=} ;; esac; done'
		printf '%s\n' '[ -n "$input" ] && exec 3<"$input"'
		printf '%s\n' 'exit 7'
	} > "$work_dir/bin/dd"
	chmod +x "$work_dir/bin/dd"

	set +e
	PATH="$work_dir/bin:$PATH" OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$work_dir" \
		UI_LIB="$UI_LIB" sh -u -c '
			. "$1"
			PAYLOAD="$2"
			PAYLOAD_UNCOMPRESSED_SIZE="$3"
			INSTALL_LOG="$4/install.log"
			ui_install_progress_stream() { cat "$1" >/dev/null; }
			ui_failure_screen() { printf "failure=%s\n" "$1"; }
			ui_leave() { :; }
			write_payload_with_percent "$4/target.raw"
		' sh "$INSTALLER" "$payload_file" "$payload_size" "$work_dir" > "$out_file" 2>&1
	status=$?
	set -e

	[ "$status" -eq 1 ] || fail "Failed dd progress smoke exited with $status instead of 1"
	assert_contains "$out_file" "dd status 7"
	assert_no_fifo "$work_dir"
}

run_parse_args_smoke() {
	work_dir="$1"
	out_file="$work_dir/parse-args.out"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$work_dir" UI_LIB="$UI_LIB" sh -eu -c '
		. "$1"
		parse_args \
			--target /dev/testdisk \
			--config-backup /tmp/router-backup.tar.gz \
			--config-import-policy full \
			--import-network wizard \
			--skip-network-wizard \
			--dry-run \
			--yes-i-know-this-will-erase-data \
			--lan-ip 10.10.10.1/24 \
			--wan-proto disabled
		printf "action=%s\n" "$action"
		printf "target=%s\n" "$TARGET"
		printf "skip_network=%s\n" "$SKIP_NETWORK"
		printf "dry_run=%s\n" "$DRY_RUN"
		printf "assume_yes=%s\n" "$ASSUME_YES"
		printf "lan=%s/%s %s\n" "$LAN_IP" "$LAN_CIDR" "$LAN_NETMASK"
		printf "wan=%s wan6=%s\n" "$WAN_PROTO" "$WAN6_PROTO"
		printf "import=%s policy=%s network=%s\n" \
			"$CONFIG_IMPORT_SOURCE_REQUEST" "$CONFIG_IMPORT_POLICY_REQUEST" \
			"$CONFIG_IMPORT_NETWORK_REQUEST"
		cleanup
	' sh "$INSTALLER" > "$out_file" 2>&1

	assert_contains "$out_file" "action=install"
	assert_contains "$out_file" "target=/dev/testdisk"
	assert_contains "$out_file" "skip_network=1"
	assert_contains "$out_file" "dry_run=1"
	assert_contains "$out_file" "assume_yes=1"
	assert_contains "$out_file" "lan=10.10.10.1/24 255.255.255.0"
	assert_contains "$out_file" "wan=disabled wan6=disabled"
	assert_contains "$out_file" "import=/tmp/router-backup.tar.gz policy=full network=wizard"
}

run_dry_run_skip_network_smoke() {
	work_dir="$1"
	out_file="$work_dir/dry-run.out"
	calls_file="$work_dir/dry-run.calls"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$work_dir" UI_LIB="$UI_LIB" OWRT_UI_MODE=line TERM=dumb sh -eu -c '
		. "$1"
		INSTALL_LOG="$2/install.log"
		TARGET="/dev/testdisk"
		SKIP_NETWORK=1
		DRY_RUN=1
		ASSUME_YES=1
		CALLS_FILE="$3"

		record() {
			printf "%s\n" "$1" >> "$CALLS_FILE"
		}

		forbidden() {
			record "$1"
			printf "forbidden call: %s\n" "$1" >&2
			exit 1
		}

		setup_ui() { record setup_ui; }
		ui_welcome_screen() { record ui_welcome_screen; }
		ui_install_stage() { record "stage:$1"; }
		verify_payload() {
			record verify_payload
			PAYLOAD_SHA256=fake-sha
		}
		validate_target_disk() { record "validate_target:$1"; }
		review_and_confirm() { record review_and_confirm; }
		select_target_disk() { forbidden select_target_disk; }
		select_network() { forbidden select_network; }
		validate_network_selection() { forbidden validate_network_selection; }
		validate_network_settings() { forbidden validate_network_settings; }
		unmount_target_partitions() { forbidden unmount_target_partitions; }
		write_payload() { forbidden write_payload; }
		resize_rootfs() { forbidden resize_rootfs; }
		write_installed_config() { forbidden write_installed_config; }

		run_install
		cleanup
	' sh "$INSTALLER" "$work_dir" "$calls_file" > "$out_file" 2>&1

	assert_contains "$calls_file" "setup_ui"
	assert_contains "$calls_file" "verify_payload"
	assert_contains "$calls_file" "validate_target:/dev/testdisk"
	assert_contains "$calls_file" "review_and_confirm"
	assert_contains "$out_file" "Dry run complete; no changes were made"
	assert_not_contains "$calls_file" "select_network"
	assert_not_contains "$calls_file" "write_payload"
	assert_not_contains "$calls_file" "resize_rootfs"
	assert_not_contains "$calls_file" "write_installed_config"
}

run_network_back_state_smoke() {
	work_dir="$1"
	out_file="$work_dir/network-back-state.out"

	OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$work_dir" UI_LIB="$UI_LIB" \
		OWRT_UI_MODE=line TERM=dumb sh -eu -c '
			. "$1"

			static_ip_calls=0
			static_gateway_calls=0
			static_dns_calls=0
			static_wan6_calls=0
			select_wan_mode() {
				SELECTED_WAN_MODE=static
			}
			select_wan6_mode() {
				static_wan6_calls=$((static_wan6_calls + 1))
				if [ "$static_wan6_calls" -eq 1 ]; then
					SELECTED_WAN6_MODE=__back
				else
					SELECTED_WAN6_MODE=disabled
				fi
			}
			prompt_default() {
				UI_INPUT_ACTION=submit
				case "$1" in
					"WAN IPv4 address/CIDR")
						static_ip_calls=$((static_ip_calls + 1))
						SELECTED_INPUT=198.51.100.2/24
						;;
					"WAN gateway")
						static_gateway_calls=$((static_gateway_calls + 1))
						if [ "$static_gateway_calls" -eq 1 ]; then
							UI_INPUT_ACTION=back
							SELECTED_INPUT=""
						else
							SELECTED_INPUT=198.51.100.1
						fi
						;;
					"WAN DNS servers")
						static_dns_calls=$((static_dns_calls + 1))
						if [ "$static_dns_calls" -eq 1 ]; then
							SELECTED_INPUT=1.1.1.1
						else
							SELECTED_INPUT=8.8.8.8
						fi
						;;
				esac
			}
			WAN_PPP_USERNAME=stale-user
			WAN_PPP_PASSWORD=stale-password
			select_wan_settings
			printf "static=%s/%s gateway=%s dns=%s wan6=%s\n" \
				"$WAN_IPADDR" "$WAN_CIDR" "$WAN_GATEWAY" "$WAN_DNS" "$WAN6_PROTO"
			printf "static_calls=%s,%s,%s,%s stale_ppp=%s,%s\n" \
				"$static_ip_calls" "$static_gateway_calls" "$static_dns_calls" "$static_wan6_calls" \
				"${#WAN_PPP_USERNAME}" "${#WAN_PPP_PASSWORD}"

			ppp_user_calls=0
			ppp_password_calls=0
			ppp_wan6_calls=0
			select_wan_mode() {
				SELECTED_WAN_MODE=pppoe
			}
			select_wan6_mode() {
				ppp_wan6_calls=$((ppp_wan6_calls + 1))
				if [ "$ppp_wan6_calls" -eq 1 ]; then
					SELECTED_WAN6_MODE=__back
				else
					SELECTED_WAN6_MODE=dhcpv6
				fi
			}
			prompt_default() {
				ppp_user_calls=$((ppp_user_calls + 1))
				UI_INPUT_ACTION=submit
				if [ "$ppp_user_calls" -eq 1 ]; then
					SELECTED_INPUT=old-user
				else
					SELECTED_INPUT=new-user
				fi
			}
			prompt_secret() {
				ppp_password_calls=$((ppp_password_calls + 1))
				case "$ppp_password_calls" in
					1)
						UI_INPUT_ACTION=submit
						SELECTED_INPUT=kept-secret
						;;
					2)
						UI_INPUT_ACTION=back
						SELECTED_INPUT=""
						;;
					*)
						UI_INPUT_ACTION=submit
						SELECTED_INPUT="$5"
						;;
				esac
			}
			WAN_IPADDR=203.0.113.2
			WAN_NETMASK=255.255.255.0
			WAN_GATEWAY=203.0.113.1
			WAN_DNS=9.9.9.9
			select_wan_settings
			printf "ppp_user=%s ppp_pass_len=%s wan6=%s\n" \
				"$WAN_PPP_USERNAME" "${#WAN_PPP_PASSWORD}" "$WAN6_PROTO"
			printf "ppp_calls=%s,%s,%s stale_static=%s,%s,%s\n" \
				"$ppp_user_calls" "$ppp_password_calls" "$ppp_wan6_calls" \
				"${#WAN_IPADDR}" "${#WAN_GATEWAY}" "${#WAN_DNS}"

			select_wan_mode() {
				SELECTED_WAN_MODE=__back
			}
			status=0
			select_wan_settings || status=$?
			printf "wan_mode_back_status=%s\n" "$status"

			loop_lan_calls=0
			loop_wan_calls=0
			select_lan_settings() {
				loop_lan_calls=$((loop_lan_calls + 1))
				return 0
			}
			select_wan_settings() {
				loop_wan_calls=$((loop_wan_calls + 1))
				if [ "$loop_wan_calls" -eq 1 ]; then
					return 2
				fi
				return 0
			}
			select_network_settings
			printf "wan_back_loop_calls=%s,%s\n" "$loop_lan_calls" "$loop_wan_calls"

			lan_calls=0
			select_lan_settings() {
				lan_calls=$((lan_calls + 1))
				return 2
			}
			select_wan_settings() {
				printf "unexpected WAN call\n" >&2
				return 1
			}
			status=0
			select_network_settings || status=$?
			printf "lan_back_status=%s lan_calls=%s\n" "$status" "$lan_calls"

			WAN_PPP_PASSWORD=cleanup-secret
			cleanup
			printf "cleanup_ppp_pass_len=%s\n" "${#WAN_PPP_PASSWORD}"
		' sh "$INSTALLER" > "$out_file" 2>&1 || {
			sed -n '1,240p' "$out_file" >&2 || true
			fail "Network Back state harness failed"
		}

	assert_contains "$out_file" "lan_back_status=2 lan_calls=1"
	assert_contains "$out_file" "static=198.51.100.2/24 gateway=198.51.100.1 dns=8.8.8.8 wan6=disabled"
	assert_contains "$out_file" "static_calls=2,2,2,2 stale_ppp=0,0"
	assert_contains "$out_file" "ppp_user=new-user ppp_pass_len=11 wan6=dhcpv6"
	assert_contains "$out_file" "ppp_calls=2,3,2 stale_static=0,0,0"
	assert_contains "$out_file" "wan_mode_back_status=2"
	assert_contains "$out_file" "wan_back_loop_calls=2,2"
	assert_contains "$out_file" "cleanup_ppp_pass_len=0"
	assert_not_contains "$out_file" "kept-secret"
}

run_line_network_wizard_back_smoke() {
	work_dir="$1"
	out_file="$work_dir/line-network-wizard-back.out"

	{
		printf '%s\n' \
			1 \
			10.0.0.1/24 \
			3 \
			198.51.100.2/24 \
			'!back' \
			198.51.100.3/24 \
			198.51.100.1 \
			1.1.1.1 \
			3 \
			8.8.8.8 \
			1
	} | OWRT_INSTALL_TEST_SOURCE_ONLY=1 TMPDIR="$work_dir" UI_LIB="$UI_LIB" \
		OWRT_UI_MODE=line TERM=dumb sh -eu -c '
			. "$1"
			setup_ui
			refresh_nics() {
				printf "%s\n" \
					"eth0|02:00:00:00:00:10" \
					"eth1|02:00:00:00:00:11" > "$NIC_LIST"
			}
			nic_label() {
				printf "%s %s" "$1" "$2"
			}

			select_network
			printf "interfaces=%s,%s macs=%s,%s\n" \
				"$LAN_DEV" "$WAN_DEV" "$LAN_MAC" "$WAN_MAC"
			printf "lan=%s/%s wan=%s/%s gateway=%s dns=%s wan6=%s\n" \
				"$LAN_IP" "$LAN_CIDR" "$WAN_IPADDR" "$WAN_CIDR" \
				"$WAN_GATEWAY" "$WAN_DNS" "$WAN6_PROTO"
			cleanup
		' sh "$INSTALLER" > "$out_file" 2>&1 || {
			sed -n '1,260p' "$out_file" >&2 || true
			fail "Line network wizard Back smoke failed"
		}

	assert_contains "$out_file" "WAN selected automatically: eth1 02:00:00:00:00:11"
	assert_contains "$out_file" "interfaces=eth0,eth1 macs=02:00:00:00:00:10,02:00:00:00:00:11"
	assert_contains "$out_file" "lan=10.0.0.1/24 wan=198.51.100.3/24 gateway=198.51.100.1 dns=8.8.8.8 wan6=dhcpv6"
}

[ -r "$INSTALLER" ] || fail "Installer not found: $INSTALLER"
[ -r "$UI_LIB" ] || fail "UI library not found: $UI_LIB"

work_dir="$(mktemp -d "$TMPDIR/owrt-install-flow-smoke.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT INT TERM

run_parse_args_smoke "$work_dir"
run_dry_run_skip_network_smoke "$work_dir"
run_network_back_state_smoke "$work_dir"
run_line_network_wizard_back_smoke "$work_dir"
run_payload_progress_smoke "$work_dir"
run_payload_progress_failure_smoke "$work_dir"

printf 'Install flow smoke tests passed.\n'
