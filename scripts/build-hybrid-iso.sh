#!/bin/sh

set -eu

# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

require_cmd fakeroot
require_cmd find
require_cmd gzip
require_cmd sha256sum
require_cmd sort
require_cmd tar

ensure_imagebuilder
mkdir -p "$OUTPUT_DIR"

targets_dir="$IMAGEBUILDER_DIR/bin/targets/x86/64"
ib_host="$IMAGEBUILDER_DIR/staging_dir/host"
grub_dir="$IMAGEBUILDER_DIR/staging_dir/target-x86_64_musl/image/grub2"
work_dir="$BUILD_DIR/hybrid-iso"
iso_root="$work_dir/root"
initramfs_root="$work_dir/initramfs"
iso_image="$OUTPUT_DIR/openwrt-x86-64-installer-hybrid.iso"
local_lib="$BUILD_DIR/host-tools/usr/lib/x86_64-linux-gnu"

kernel="$(find "$targets_dir" -maxdepth 1 -type f \
	-name "*-${PROFILE}-kernel.bin" | head -n 1)"
rootfs="$(find "$targets_dir" -maxdepth 1 -type f \
	-name "*-${PROFILE}-rootfs.tar.gz" | head -n 1)"

[ -n "$kernel" ] || die "Installer kernel is missing. Run: make installer"
[ -n "$rootfs" ] || die "Installer rootfs tarball is missing. Run: make installer"
[ -s "$OUTPUT_DIR/openwrt-x86-64-installer.img.gz" ] ||
	die "Installer image is missing. Run: make installer"
[ -s "$PROJECT_DIR/files-installer/usr/share/owrt-installer/target.img.gz" ] ||
	die "Embedded target payload is missing. Run: make installer"
[ -x "$ib_host/bin/mkfs.fat" ] || die "ImageBuilder mkfs.fat tool is missing"
[ -x "$ib_host/bin/mcopy" ] || die "ImageBuilder mcopy tool is missing"
[ -x "$ib_host/bin/mmd" ] || die "ImageBuilder mmd tool is missing"
[ -s "$grub_dir/boot.img" ] || die "GRUB MBR image is missing"
[ -s "$grub_dir/cdboot.img" ] || die "GRUB CD boot image is missing"
[ -s "$grub_dir/eltorito.img" ] || die "GRUB El Torito image is missing"
[ -s "$grub_dir/iso-bootx64.efi" ] || die "GRUB EFI image is missing"
[ -s "$IMAGEBUILDER_DIR/target/linux/generic/other-files/init" ] ||
	die "OpenWrt initramfs init script is missing"

if [ -x "$BUILD_DIR/host-tools/usr/bin/xorrisofs" ]; then
	xorrisofs="$BUILD_DIR/host-tools/usr/bin/xorrisofs"
	xorriso_lib="$local_lib"
elif command -v xorrisofs >/dev/null 2>&1; then
	xorrisofs="$(command -v xorrisofs)"
	xorriso_lib=""
else
	die "xorrisofs is required. Install xorriso or run: make iso-host-tools"
fi

if command -v cpio >/dev/null 2>&1; then
	cpio="$(command -v cpio)"
else
	die "cpio is required. Install cpio or run: make iso-host-tools"
fi

run_xorrisofs() {
	if [ -n "$xorriso_lib" ]; then
		LD_LIBRARY_PATH="$xorriso_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
			"$xorrisofs" "$@"
	else
		"$xorrisofs" "$@"
	fi
}

rm -rf "$work_dir"
mkdir -p "$iso_root/boot/grub" "$iso_root/efi/boot" "$initramfs_root"

log "Creating RAM-root initramfs"
tar -xzf "$rootfs" -C "$initramfs_root"
cp "$IMAGEBUILDER_DIR/target/linux/generic/other-files/init" "$initramfs_root/init"

# shellcheck disable=SC2016 # Expanded by the nested shell after positional args are passed.
fakeroot sh -eu -c '
	root="$1"
	cpio="$2"

	mkdir -p "$root/dev/pts"
	mknod "$root/dev/console" c 5 1
	mknod "$root/dev/null" c 1 3
	mknod "$root/dev/zero" c 1 5
	mknod "$root/dev/tty" c 5 0
	mknod "$root/dev/tty0" c 4 0
	mknod "$root/dev/tty1" c 4 1
	mknod "$root/dev/random" c 1 8
	mknod "$root/dev/urandom" c 1 9
	chmod 600 "$root/dev/console"
	chmod 666 "$root/dev/null" "$root/dev/zero" "$root/dev/tty"
	chmod 660 "$root/dev/tty0" "$root/dev/tty1"
	chmod 666 "$root/dev/random" "$root/dev/urandom"

	cd "$root"
	find . -print | LC_ALL=C sort | "$cpio" --reproducible -o -H newc -R 0:0
' sh "$initramfs_root" "$cpio" |
	gzip -9n > "$iso_root/boot/initramfs.cpio.gz"

cp "$kernel" "$iso_root/boot/vmlinuz"
cp "$PROJECT_DIR/iso/boot/grub/grub.cfg" "$iso_root/boot/grub/grub.cfg"
cp "$grub_dir/iso-bootx64.efi" "$iso_root/efi/boot/bootx64.efi"
cat "$grub_dir/cdboot.img" "$grub_dir/eltorito.img" > \
	"$iso_root/boot/grub/eltorito.img"

log "Creating EFI boot image"
"$ib_host/bin/mkfs.fat" --invariant -C "$iso_root/boot/grub/isoboot.img" -S 512 1440
"$ib_host/bin/mmd" -i "$iso_root/boot/grub/isoboot.img" ::/efi ::/efi/boot
"$ib_host/bin/mcopy" -i "$iso_root/boot/grub/isoboot.img" \
	"$grub_dir/iso-bootx64.efi" ::/efi/boot/bootx64.efi

log "Building BIOS/UEFI hybrid ISO"
run_xorrisofs \
	-R \
	-J \
	-V OWRT_INSTALL \
	-o "$iso_image" \
	--grub2-mbr "$grub_dir/boot.img" \
	-partition_offset 16 \
	--mbr-force-bootable \
	-append_partition 2 0xef "$iso_root/boot/grub/isoboot.img" \
	-appended_part_as_gpt \
	-no-pad \
	-b boot/grub/eltorito.img \
	-c boot/grub/boot.cat \
	-no-emul-boot \
	-boot-load-size 4 \
	-boot-info-table \
	--grub2-boot-info \
	-eltorito-alt-boot \
	-e --interval:appended_partition_2:all:: \
	-no-emul-boot \
	"$iso_root"

sha256sum "$iso_image" > "$iso_image.sha256"
update_output_checksums

log "Hybrid ISO ready: $iso_image"
