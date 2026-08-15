# Physical x86 Storage And Rescue Acceptance

This procedure is the mandatory bare-metal gate for the first release that
contains selectable OpenWrt partition sizing and existing-install rescue.
QEMU results are necessary but do not replace this test.

## Safety And Candidate Identity

Use a disposable x86_64 machine, one non-essential SATA SSD, and one
non-essential NVMe disk. Every install step below destroys the selected disk.
Disconnect disks containing the only copy of important data.

Freeze the exact clean candidate before testing:

```sh
make freeze-candidate VERSION=v1.0-alpha.N
```

Verify `output/sha256sums.txt` and record the committed candidate metadata.
Do not rebuild the ISO or change runtime files during the test. A changed ISO,
runtime commit, or installer version requires a new candidate and new report.

## Required Hardware

- a local display, wired USB mouse, and USB keyboard;
- one disposable SATA SSD and one disposable NVMe disk;
- at least two network interfaces for LAN/WAN selection;
- enough RAM for the embedded payload and rescue snapshot.

## 1. Navigation And No-write Gate

1. In GRUB, edit **OpenWrt x86 Installer** and append
   `owrt.hardware-test=1` to the `linux` line. Keep `owrt.mouse=1`.
2. Boot with Ctrl+X or F10 and confirm `HARDWARE TEST / DRY RUN`.
3. With the mouse, select a target and open the existing-install action and
   storage-size menus when available. Also complete one menu with Up/Down and
   Enter.
4. Reach the exact `ERASE /dev/...` prompt. Confirm that the mouse is stopped,
   enter the phrase with the keyboard, and verify the final no-changes dialog.

## 2. SATA Bounded Install

1. Boot the normal installer and select only the disposable SATA SSD.
2. Choose a clean installation and a fixed size such as `4 GiB`.
3. Confirm that review shows the expected root size and an unallocated tail.
4. Enter the exact phrase, install, remove or detach the ISO, and boot the SSD.
5. Confirm that OpenWrt boots, partition 2 has the requested sector geometry,
   the ext4 root is usable, and the remaining disk tail is unallocated.

## 3. NVMe Bounded Install

Repeat the SATA procedure on the disposable NVMe disk with a different fixed
or custom size, such as `8 GiB`. Confirm installed boot, partition 2 geometry,
ext4 availability, and the unallocated tail.

Use sector values from `fdisk -l` or `parted -m -s DEVICE unit s print` rather
than rounded human-readable capacity as the authoritative partition check.

## 4. Existing OpenWrt Rescue

1. Boot the OpenWrt installed on one disposable disk and set recognizable,
   non-secret LAN/WAN and hostname values. Reboot once and confirm they work.
2. Boot the candidate ISO, select that disk, and confirm that its OpenWrt
   version and ext4 root are detected.
3. Choose **Rescue and upgrade**, then **Configuration only**, and keep the
   rescued network configuration.
4. Confirm that the review shows a RAM snapshot hash, source/target versions,
   selected policy, and requested root geometry.
5. Install, boot the rescued system, and verify the hostname and LAN/WAN UCI
   values. Confirm that the rescued package inventory was informational only
   and that packages were not silently installed.

## 5. Pre-ERASE Power-cycle Gate

1. Boot the source OpenWrt and add another recognizable non-secret UCI value.
2. Boot the ISO, choose rescue, and continue until the review confirms that a
   validated snapshot is in RAM. Do not enter the exact erase phrase.
3. Cancel, or power the machine off at that point.
4. Boot the existing disk directly and verify that its partition geometry,
   filesystem, and added UCI value are unchanged.

## 6. Generate And Verify The Report

Run the no-write hardware-test flow once more on the unchanged frozen
candidate, then run:

```sh
owrt-hardware-report
```

Answer `pass` only for checks actually completed above. Preserve
`/tmp/owrt-hardware-report.txt` before rebooting the RAM-root installer. On the
build host run:

```sh
./scripts/verify-physical-report.sh /path/to/owrt-hardware-report.txt
make release-gate \
  CANDIDATE=release/v1.0-alpha.N-candidate.env \
  REPORT=/path/to/owrt-hardware-report.txt
```

Schema 3 requires all of these results:

```text
manual_storage_rescue_navigation=pass
manual_sata_root_size_and_boot=pass
manual_nvme_root_size_and_boot=pass
manual_rescue_restore=pass
manual_pre_erase_power_cycle_no_change=pass
physical_flow_result=pass
```

The existing wired USB mouse, keyboard, exact-prompt cleanup, dry-run, and
runtime-cleanup gates remain mandatory. Do not include serial numbers, MAC
addresses, public IP addresses, passwords, private configuration, or raw logs
in the report.
