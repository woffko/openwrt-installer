#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/qemu-uefi"
INSTALLER_GZ="$PROJECT_DIR/output/openwrt-x86-64-installer.img.gz"
INSTALLER_RAW="$BUILD_DIR/installer.img"
TARGET_DISK="$BUILD_DIR/test-target.qcow2"
VARS_COPY="$BUILD_DIR/OVMF_VARS.fd"
MODE="${1:-install}"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

find_first_file() {
	for file in "$@"; do
		if [ -f "$file" ]; then
			printf '%s\n' "$file"
			return 0
		fi
	done
	return 1
}

command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 is required"
command -v qemu-img >/dev/null 2>&1 || die "qemu-img is required"

OVMF_CODE="${OVMF_CODE:-$(find_first_file \
	/usr/share/OVMF/OVMF_CODE.fd \
	/usr/share/edk2/x64/OVMF_CODE.fd \
	/usr/share/qemu/OVMF_CODE.fd || true)}"
OVMF_VARS="${OVMF_VARS:-$(find_first_file \
	/usr/share/OVMF/OVMF_VARS.fd \
	/usr/share/edk2/x64/OVMF_VARS.fd \
	/usr/share/qemu/OVMF_VARS.fd || true)}"

[ -f "$OVMF_CODE" ] || die "OVMF_CODE.fd not found; set OVMF_CODE explicitly"
[ -f "$OVMF_VARS" ] || die "OVMF_VARS.fd not found; set OVMF_VARS explicitly"

mkdir -p "$BUILD_DIR"
[ -f "$VARS_COPY" ] || cp "$OVMF_VARS" "$VARS_COPY"

if [ ! -f "$TARGET_DISK" ]; then
	qemu-img create -f qcow2 "$TARGET_DISK" 4G
fi

case "$MODE" in
	install)
		[ -s "$INSTALLER_GZ" ] || die "Installer image is missing. Run: make all"
		gzip -dc "$INSTALLER_GZ" > "$INSTALLER_RAW"
		printf 'UEFI installer test. Inside OpenWrt run:\n'
		printf '  owrt-install --list-disks\n'
		printf '  owrt-install --list-nics\n'
		printf '  owrt-install --target /dev/vdb --lan-mac <first-mac> --wan-mac <second-mac>\n'
		exec qemu-system-x86_64 \
			-machine q35,accel=kvm:tcg \
			-m 1024 \
			-smp 2 \
			-nographic \
			-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
			-drive "if=pflash,format=raw,file=$VARS_COPY" \
			-drive "file=$INSTALLER_RAW,format=raw,if=virtio,readonly=on" \
			-drive "file=$TARGET_DISK,format=qcow2,if=virtio" \
			-nic user,model=e1000 \
			-nic user,model=e1000
		;;
	boot)
		printf 'UEFI installed-target boot test.\n'
		exec qemu-system-x86_64 \
			-machine q35,accel=kvm:tcg \
			-m 1024 \
			-smp 2 \
			-nographic \
			-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
			-drive "if=pflash,format=raw,file=$VARS_COPY" \
			-drive "file=$TARGET_DISK,format=qcow2,if=virtio" \
			-nic user,model=e1000 \
			-nic user,model=e1000
		;;
	*)
		die "Usage: $0 [install|boot]"
		;;
esac
