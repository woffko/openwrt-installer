# OpenWrt x86_64 Installer

[![Smoke](https://github.com/woffko/openwrt-installer/actions/workflows/smoke.yml/badge.svg)](https://github.com/woffko/openwrt-installer/actions/workflows/smoke.yml)

Minimal OpenWrt-based disk installer for x86_64 routers. The project builds an
OpenWrt `25.12.5` live USB image containing a prebuilt target image. The
`owrt-install` wizard writes that payload to an SSD, NVMe, SATA, or virtual
disk and expands its ext4 root filesystem. An optional boot-menu path can
instead download and verify the latest official stable OpenWrt x86 image in
RAM before running the same installation flow. After target selection, the
interactive installer can also restore a validated OpenWrt configuration
backup from a read-only USB partition instead of performing a clean install.

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

The build scripts use the official OpenWrt `25.12.5` x86/64 ImageBuilder.
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

QEMU tests additionally require `qemu-system-x86_64`, `qemu-img`, OVMF for
UEFI testing, and `nc` for the VGA framebuffer smoke test. `shellcheck` is
optional but recommended.

## Build

Build the target and live installer:

```sh
make all
```

Build individual stages:

```sh
make download
make target
make mouse-packages
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

The GRUB menu provides the embedded RAM installer, the verified online
installer, a **Boot installed OpenWrt from local disk** entry, the hardware
mouse dry-run, the experimental mouse installer, and a failsafe entry. Local
disk boot searches for the installed OpenWrt `kernel` partition and loads its
own GRUB configuration; it is covered in both BIOS and UEFI QEMU tests.

### Online install

Select **Download latest OpenWrt x86 image and install** in GRUB to use the
online path. The installer first checks existing connectivity and, when no
default route is available, automatically tries temporary DHCP on detected
Ethernet interfaces, preferring an active link. If HTTPS is still unavailable,
it offers manual DHCP, static IPv4, or PPPoE setup for a selected uplink.
Cancelling or any recoverable network failure allows returning to the embedded
OpenWrt `25.12.5` payload.

The online path accepts only the exact official x86/64 generic ext4 combined
image for the active boot mode: `ext4-combined` for BIOS or
`ext4-combined-efi` for UEFI. It verifies the signed checksum list with the
pinned OpenWrt release key, then checks SHA-256, compressed size, gzip
integrity, available RAM, and the expected partition layout before target-disk
selection. The review screen shows the downloaded version, filename, hash,
boot mode, and RAM sizing. Nothing is streamed directly to the target disk;
the fully verified image stays in RAM and uses the same exact
`ERASE /dev/...` confirmation and write path as an embedded install.

### Import OpenWrt configuration from USB

After selecting the target disk, choose **Import OpenWrt backup from USB** to
restore a standard `sysupgrade -b` `.tar.gz` or `.tgz` archive. The picker
supports FAT32, exFAT, NTFS3, and ext4 USB partitions. It mounts the selected
partition read-only, copies the archive into private RAM, unmounts the USB,
and validates every member before showing the destructive review.

**Configuration only** is the recommended scope and restores only
`/etc/config`. **Full OpenWrt backup** is an advanced option that restores all
validated `/etc` content and can include passwords, SSH keys, and first-boot
scripts. When the backup contains `/etc/config/network`, the wizard can either
keep that network configuration or replace it with new LAN/WAN settings.
Package lists found in the backup are shown as metadata but are not installed
automatically.

Archives with unsafe paths, links, special files, ambiguous members, excessive
sizes, or insufficient available RAM are rejected. Extraction occurs only in
a private RAM staging directory and is audited again before it is copied to
the installed root filesystem. The review includes the source, policy, member
count, and SHA-256; installation still requires the exact `ERASE /dev/...`
confirmation.

The same path is available for automation:

```sh
owrt-install --target /dev/nvme0n1 \
  --config-backup /path/to/backup.tar.gz \
  --config-import-policy config-only \
  --import-network keep
```

Use `--config-import-policy full` only for a trusted complete backup. Use
`--import-network wizard` to configure LAN/WAN after importing it.

Useful diagnostics:

```sh
owrt-install --list-disks
owrt-install --list-nics
```

## Installer UI

Interactive local-console installs use the packaged Hellforge `whiptail` TUI.
It keeps the installer keyboard-first with arrow-key menus, Cancel/`Esc` Back,
framed review screens, destructive warnings, and install-stage status screens.
Network forms show context, examples, defaults, and local validation errors
before the final review. Serial, dumb terminals, pipes, and narrow terminals
fall back to the plain numbered line UI. Full-screen auto mode requires a
terminal of at least `80x24`.

Network forms support step-by-step Back navigation. Press `Esc` in an ANSI
form, use Cancel in a curses form, or enter `!back` in the line UI. Enter
`!!back` when the literal value `!back` is required. WAN mode and WAN IPv6
menus include explicit Back items. Values already entered are retained while
moving between fields, but credentials and static settings for an unused WAN
protocol are cleared before review.

In SSH and xterm-compatible terminal emulators, ANSI menus also accept direct
mouse clicks and wheel scrolling through the standard SGR mouse protocol. The
same menus always remain usable with Up/Down and Enter. Mouse tracking is
enabled only while a menu is open and is disabled during cleanup. Set
`OWRT_UI_NO_MOUSE=1` to force keyboard-only operation.

Local VGA mouse input is available as an experimental, disabled-by-default
mode. Select **Installer (experimental mouse)** in GRUB, append `owrt.mouse=1`
to the installer kernel command line, or use
`OWRT_LOCAL_MOUSE_ENABLE=1 owrt-install` for a manual session on `tty1`. The
image contains GPM-enabled Newt/whiptail packages built by the pinned OpenWrt
SDK. The stock Linux `mousedev` compatibility handler combines relative and
absolute pointers into `/dev/input/mice`; GPM consumes its standard IMPS/2
stream, so the installer does not select VMware twin `eventX` devices or decode
`EV_ABS` itself. Newt draws the existing Linux-console selection-cell pointer
instead of moving the blinking text cursor. Serial consoles and SSH do not
activate this path. Failure or termination of the mouse daemon leaves all menus
usable by keyboard. Connect the pointer before the installer starts; this
prototype does not retry device discovery after hotplug.

The mouse daemon is stopped and its private `0600` socket is removed before
the exact `ERASE /dev/...` phrase. That destructive phrase is always entered
with the keyboard. The previous direct-evdev implementation passed QEMU but
failed its VMware cursor test and has been replaced by the kernel multiplexer.
The replacement path passed the automated QEMU USB, PS/2, absolute-tablet,
crash, cleanup, and fallback matrix, and its VMware cursor test on 2026-08-14.
The mode remains experimental until the separate physical x86 gate is
completed.

For bare-metal validation, GRUB also provides **Mouse hardware test (no disk
writes)**. It runs the real disk and network wizard, including the exact erase
gate, with `--dry-run` forced from the kernel command line. A successful flow
ends with an explicit no-changes dialog. Run `owrt-hardware-report` afterward
to create a privacy-safe acceptance report with a machine-readable verdict.
After preserving that report, validate the wired USB alpha gate on the build
host with `./scripts/verify-physical-report.sh REPORT`. Follow
[PHYSICAL_X86_MOUSE_TEST.md](PHYSICAL_X86_MOUSE_TEST.md); use a disposable test
machine and non-essential target disk even in dry-run mode.

UI mode can be forced for debugging:

```sh
OWRT_UI_MODE=line owrt-install
OWRT_UI_MODE=ansi owrt-install
OWRT_UI_MODE=whiptail owrt-install
OWRT_UI_MODE=curses owrt-install
OWRT_UI_MODE=dialog owrt-install
```

`curses` selects `dialog` when available, then `whiptail`, then ANSI. In auto
mode the local Linux console uses the required `whiptail` package. SSH and
xterm-compatible terminals keep the native ANSI backend so SGR mouse support
remains available. The optional `dialog --mouse` backend is still supported,
but OpenWrt `25.12.5` does not currently provide that package in this feed.

Before the final destructive confirmation, the review screen offers a safe
action menu: continue to the exact `ERASE /dev/...` prompt, edit LAN/WAN
interfaces and network settings, or cancel back to the shell.

During the payload write, the installer uses the packaged `pv` utility and the
manifest's uncompressed size to show byte-accurate percentage progress. The
local curses UI uses a native gauge; ANSI and line modes render the same
numeric stream. `gzip`, `pv`, and `dd` are tracked independently so a failure
from any stage is reported instead of being hidden by a shell pipeline. Other
disk and filesystem operations show stage progress and the last few lines from
`/tmp/owrt-installer.log`. If exact sizing or `pv` is unavailable, the runtime
falls back to stage-only progress. Command output stays out of the TUI, and a
failure screen shows the log path and a short log tail before returning to the
shell.

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
The interactive PPPoE flow asks for the username and hidden password on two
separate screens. Back returns one field at a time, entered values are retained
while editing, and the password is never shown on the review screen.
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

- Validate experimental local VGA mouse input on physical x86 hardware before
  enabling it by default or documenting it as a supported input path.

## Checks

Run the fast non-ISO regression gate:

```sh
make smoke
```

Run POSIX shell syntax checks:

```sh
make syntax-check
```

Run ShellCheck when installed:

```sh
make shellcheck
```

Run fast UI regression smoke tests for line, ANSI snapshot rendering,
Ctrl+C cleanup, Esc cancel, real `whiptail` pseudo-TTY interaction, backend
fallback, and terminal-size behavior:

```sh
make ui-smoke
```

Run safe install-flow smoke tests for CLI flags and dry-run guards:

```sh
make install-flow-smoke
```

Run the deterministic USB backup validation and restore matrix without QEMU:

```sh
make config-import-smoke
```

After `make iso`, run only the USB backup install and installed-system boot
acceptance:

```sh
make config-import-qemu-smoke
```

Run the experimental local-console mouse QEMU matrix after `make iso`:

```sh
make mouse-qemu-smoke
```

It covers USB relative click navigation, PS/2 activation, absolute-only tablet
click navigation through `/dev/input/mice`, daemon-crash keyboard fallback,
cleanup before the exact erase confirmation, the forced hardware dry-run flow,
and target-disk immutability.

Run the full automated hybrid ISO gate after `make iso`. It covers BIOS, UEFI,
local-disk boot and its missing-disk path, the hardware-test menu, the VGA
curses framebuffer, clean installation to a disposable qcow2 disk, USB backup
import, and boot validation of both installed systems:

```sh
make iso-smoke
```

Run only the automated install and installed-system boot check:

```sh
make install-smoke
```

Run only the VGA backend/framebuffer check:

```sh
make vga-smoke
```

Run only the BIOS/UEFI installed-system boot-through-ISO checks, including the
missing-local-disk path:

```sh
make local-disk-boot-smoke
```

Run the deterministic online failure/success matrix without QEMU:

```sh
make online-install-smoke
```

After `make iso`, run real online BIOS and UEFI download/install/boot checks:

```sh
make online-install-qemu-smoke
```

Before a physical test, commit the intended release runtime and make sure the
repository is clean. Build and test that exact non-`-dev` version, then create
immutable candidate metadata:

```sh
make iso
make smoke
make mouse-qemu-smoke
make iso-smoke
make freeze-candidate VERSION=v1.0-alpha.N
```

`freeze-candidate` never commits automatically. It refuses dirty repositories,
development versions, stale artifacts, checksum failures, and manifests built
from another or dirty commit. Review and commit the newly created
`release/v1.0-alpha.N-candidate.env` before collecting a physical report. Do
not rebuild or change runtime files afterward.

After completing the documented wired USB test, run the immutable gate before
creating the alpha release:

```sh
make release-gate \
  CANDIDATE=release/v1.0-alpha.N-candidate.env \
  REPORT=/path/to/owrt-hardware-report.txt
```

The gate uses a strict data-only metadata parser and verifies the committed
candidate file, physical report, full runtime commit, tracked/staged/untracked
and unexpected ignored runtime state, ISO and sidecar hashes, manifest version,
and `build_commit`/`build_dirty` provenance. It also extracts `/manifest.json`
from the ISO and requires it to match `output/manifest.json` byte-for-byte.

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
VLANs, multiple LAN ports, Wi-Fi setup, encrypted installation, Secure Boot,
or non-ext4 target filesystems.
