CUSTOM_BUILD - local OpenWrt x86 images

Place custom OpenWrt x86/64 generic ext4 combined images directly in this
directory. Supported files end in .img.gz.

BIOS installer boot:
  openwrt-<version>-x86-64-generic-ext4-combined.img.gz

UEFI installer boot:
  openwrt-<version>-x86-64-generic-ext4-combined-efi.img.gz

Optional checksum files:
  <image filename>.sha256
  sha256sums

The installer copies the selected image into private RAM, unmounts the source,
checks its SHA-256, gzip stream, true decompressed size, partition table, ext4
root filesystem, and current BIOS/UEFI mode before target disk selection.

Custom images are not authenticated by the official OpenWrt release key. A
matching local checksum detects accidental corruption but does not establish
who created the image. Use only images you built or independently verified.

Hybrid ISO filesystems are read-only after creation. To add an image, use a
Ventoy or separate USB partition with /CUSTOM_BUILD, or rebuild/remaster the
ISO. The raw ext4 installer image can be mounted and populated from Linux.
