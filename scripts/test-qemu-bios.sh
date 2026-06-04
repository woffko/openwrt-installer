#!/bin/sh

set -eu

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/qemu-bios"
INSTALLER_GZ="$PROJECT_DIR/output/openwrt-x86-64-installer.img.gz"
INSTALLER_RAW="$BUILD_DIR/installer.img"
TARGET_DISK="$BUILD_DIR/test-target.qcow2"
MODE="${1:-install}"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 is required"
command -v qemu-img >/dev/null 2>&1 || die "qemu-img is required"
mkdir -p "$BUILD_DIR"

if [ ! -f "$TARGET_DISK" ]; then
	qemu-img create -f qcow2 "$TARGET_DISK" 4G
fi

case "$MODE" in
	install)
		[ -s "$INSTALLER_GZ" ] || die "Installer image is missing. Run: make all"
		gzip -dc "$INSTALLER_GZ" > "$INSTALLER_RAW"
		printf 'BIOS installer test. Inside OpenWrt run:\n'
		printf '  owrt-install --list-disks\n'
		printf '  owrt-install --list-nics\n'
		printf '  owrt-install --target /dev/vdb --lan-mac <first-mac> --wan-mac <second-mac>\n'
		exec qemu-system-x86_64 \
			-machine q35,accel=kvm:tcg \
			-m 1024 \
			-smp 2 \
			-nographic \
			-drive "file=$INSTALLER_RAW,format=raw,if=virtio,readonly=on" \
			-drive "file=$TARGET_DISK,format=qcow2,if=virtio" \
			-nic user,model=e1000 \
			-nic user,model=e1000
		;;
	boot)
		printf 'BIOS installed-target boot test.\n'
		exec qemu-system-x86_64 \
			-machine q35,accel=kvm:tcg \
			-m 1024 \
			-smp 2 \
			-nographic \
			-drive "file=$TARGET_DISK,format=qcow2,if=virtio" \
			-nic user,model=e1000 \
			-nic user,model=e1000
		;;
	*)
		die "Usage: $0 [install|boot]"
		;;
esac
