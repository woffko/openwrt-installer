# OpenWrt x86_64 Installer

Minimal OpenWrt-based disk installer for x86_64 routers. The project builds an
OpenWrt `25.12.4` live USB image containing a prebuilt target image. The
`owrt-install` wizard writes that payload to an SSD, NVMe, SATA, or virtual
disk and expands its ext4 root filesystem.

Repository: <https://github.com/woffko/openwrt-installer>

This is an MVP. It supports one LAN interface, one WAN interface, DHCP on LAN,
DHCP/DHCPv6 clients on WAN, firewall forwarding from LAN to WAN, NAT, SSH, and
LuCI. Interface selection is saved by MAC address so installed-system device
names do not need to match names used by the live installer.

## Warning

Installation completely erases the selected disk. Review the target carefully.
Do not select the USB device that booted the installer. Removable disks are
blocked unless `--allow-removable` is passed explicitly.

## Host requirements

The build scripts use the official OpenWrt `25.12.4` x86/64 ImageBuilder.
Install these host commands:

```text
curl gzip make sha256sum tar zstd
```

Hybrid ISO creation additionally requires `fakeroot`, `cpio`, and `xorriso`.
If `cpio` or `xorriso` is unavailable on the host, download local copies into
`build/`:

```sh
make iso-host-tools
```

QEMU tests additionally require `qemu-system-x86_64`, `qemu-img`, and OVMF for
UEFI testing. `shellcheck` is optional but recommended.

## Build

Build the target and live installer:

```sh
make all
```

Build individual stages:

```sh
make download
make target
make installer
make iso
```

Generated artifacts:

```text
output/openwrt-x86-64-target.img.gz
output/openwrt-x86-64-installer.img.gz
output/openwrt-x86-64-installer-hybrid.iso
output/manifest.json
output/sha256sums.txt
```

Package lists are in `profiles/`. Required packages stop the build when they
are unavailable. Optional packages use `<scope> <package>` entries in
`profiles/optional-packages.txt`; missing optional packages are logged and
skipped.

## Write USB

Replace `/dev/sdX` with the whole USB disk, not a partition:

```sh
gzip -dc output/openwrt-x86-64-installer.img.gz |
  sudo dd of=/dev/sdX bs=16M conv=fsync status=progress
```

Boot that USB device. The disk installer starts automatically on `tty1` after
boot messages and device discovery settle. It can also be started manually:

```sh
owrt-install
```

## Hybrid ISO

Build the BIOS/UEFI hybrid ISO after `make installer`:

```sh
make iso
```

The resulting `output/openwrt-x86-64-installer-hybrid.iso` boots the same
installer from RAM. It can be attached as a virtual CD, used with Ventoy, or
written directly to a USB drive with Rufus, balenaEtcher, or `dd`.

The `.iso` and `.img.gz` variants contain the same target payload. Prefer the
hybrid ISO for convenient boot media and the raw `.img.gz` image as a simple
fallback.

Useful diagnostics:

```sh
owrt-install --list-disks
owrt-install --list-nics
```

## Installer UI

Interactive local-console installs use the zero-dependency Hellforge ANSI TUI
when the terminal is suitable. It keeps the installer keyboard-first with
arrow-key menus, framed review screens, destructive-action warnings, and
install-stage status screens. Network forms show context, examples, defaults,
and local validation errors before the final review. Serial, dumb terminals,
pipes, and narrow terminals fall back to the plain numbered line UI.

UI mode can be forced for debugging:

```sh
OWRT_UI_MODE=line owrt-install
OWRT_UI_MODE=ansi owrt-install
OWRT_UI_MODE=dialog owrt-install
```

Mouse support is available only through the optional runtime `dialog --mouse`
backend when the `dialog` package is present and the terminal forwards mouse
events. The standard build currently falls back to ANSI because the OpenWrt
`25.12.4` ImageBuilder used here does not provide the optional `dialog`
package. Use `OWRT_UI_NO_MOUSE=1` to force keyboard-only `dialog` mode.

Unattended-style invocation still requires the explicit destructive flag:

```sh
owrt-install --target /dev/nvme0n1 \
  --lan-mac xx:xx:xx:xx:xx:xx \
  --wan-mac yy:yy:yy:yy:yy:yy \
  --lan-ip 192.168.1.1/24 \
  --wan-proto dhcp \
  --yes-i-know-this-will-erase-data
```

WAN modes supported by the wizard are DHCP, PPPoE, static IPv4, and disabled.
For PPPoE use `--wan-proto pppoe --pppoe-username USER --pppoe-password PASS`.
For static WAN use `--wan-proto static --wan-ip 198.51.100.2/24
--wan-gateway 198.51.100.1 --wan-dns "1.1.1.1 8.8.8.8"`.
WAN IPv6 is configured as a separate type: DHCPv6 / Prefix Delegation or None.
For IPv6 over PPPoE, keep IPv4 WAN as PPPoE and choose DHCPv6 / Prefix
Delegation for WAN IPv6.

Use `--skip-network-wizard` to keep default OpenWrt network configuration.
Use `--dry-run` to validate a selection without writing to disk.

## Installed router

During installation, selected MAC addresses are written to
`/etc/owrt-installer/interface-map`. On first boot,
`/etc/uci-defaults/98-installer-network` resolves the current Linux interface
names and creates:

```text
br-lan with the selected LAN port
LAN static IPv4 from the wizard with DHCP server
WAN DHCP, PPPoE, static IPv4, or disabled
optional WAN6 DHCPv6 client
firewall LAN -> WAN forwarding with NAT when WAN is enabled
```

The installed system also contains `/etc/openwrt-installer-release`.

## Future Work

- Add an OpenWrt configuration import step after target disk selection: choose
  between a clean install or importing configs/backups from a USB drive.

## Checks

Run POSIX shell syntax checks:

```sh
make syntax-check
```

Run ShellCheck when installed:

```sh
make shellcheck
```

QEMU scripts are semi-manual smoke tests:

```sh
./scripts/test-qemu-uefi.sh install
./scripts/test-qemu-uefi.sh boot
./scripts/test-qemu-bios.sh install
./scripts/test-qemu-bios.sh boot
```

See `tests/qemu/README.md` for the guest workflow.

## MVP limits

The MVP intentionally does not implement a web installer, package selection,
VLANs, multiple LAN ports, Wi-Fi setup, backup/config imports, encrypted
installation, Secure Boot, or non-ext4 target filesystems.
