# Physical x86 Storage, Upgrade, And Rescue Acceptance

This is the mandatory bare-metal gate for a release containing storage
profiles, installer-managed data partitions, the persistent sysupgrade guard,
Hellforge Safe Upgrade, or existing-install rescue. QEMU evidence does not
replace this procedure.

## Safety And Candidate Identity

Use a disposable x86_64 machine, one non-essential SATA SSD, and one
non-essential NVMe disk. Every clean/import/reinstall step destroys the
selected disk. Disconnect disks containing the only copy of important data.

Commit the intended runtime, build the exact clean pre-candidate, and complete
the automated gates before testing. Do not freeze candidate metadata yet:

```sh
make iso
make smoke
make iso-smoke
make storage-device-qemu-smoke
cd output && sha256sum -c sha256sums.txt
```

Record `output/sha256sums.txt`, `output/manifest.json`, and the full runtime
commit. Do not rebuild the ISO or change runtime files during the test. The
hardware report records the embedded manifest SHA-256, runtime commit, clean
build flag, and payload SHA-256. A changed ISO, manifest, runtime commit, or
installer version requires a new physical report.

## Required Hardware

- a local display, wired USB mouse, and USB keyboard;
- one disposable SATA SSD and one disposable NVMe disk;
- at least two network interfaces for LAN/WAN selection;
- enough RAM for the rescue snapshot and, after it is created, the complete
  uncompressed payload plus the Safe Upgrade `128 MiB` operating reserve;
- the candidate target `.img.gz` on removable media for standard sysupgrade.

Use sector values from `fdisk -l` or
`parted -m -s DEVICE unit s print`. Rounded capacities are not authoritative.

## 1. Navigation And No-write Gate

1. In GRUB, edit **OpenWrt x86 Installer** and append
   `owrt.hardware-test=1` to the `linux` line. Keep `owrt.mouse=1`.
2. Boot with Ctrl+X or F10 and confirm `HARDWARE TEST / DRY RUN`.
3. Navigate the storage profile, custom data partition, existing-install,
   rescue, and network screens with the mouse. Complete one menu with Up/Down
   and Enter.
4. Reach the exact `ERASE /dev/...` prompt. Confirm the mouse is stopped,
   enter the phrase with the keyboard, and verify the final no-changes dialog.

## 2. SATA Compatible Install

1. Boot the normal installer and select only the disposable SATA SSD.
2. Choose a clean installation and **OpenWrt-compatible (recommended)**.
3. Confirm review shows unchanged payload partitions 1/2, one ext4 data
   partition, and an unallocated SSD reserve.
4. Enter the exact erase phrase, install, detach the ISO, and boot the SSD.
5. Verify partition 3 is ext4, mounted at `/mnt/data` by UUID, and matches
   `/etc/config/owrt-installer`, `/etc/config/fstab`, and
   `/etc/owrt-installer/storage-layout`.
6. Verify p3 uses the aligned 80% calculation documented in
   `STORAGE_AND_RESCUE_PLAN.md`, the final reserve is non-zero and unallocated,
   `/sbin/sysupgrade` is the Hellforge wrapper, and
   `/sbin/sysupgrade.openwrt` exists.

## 3. NVMe Compatible Install

Repeat the compatible installation on the disposable NVMe disk. Confirm the
same p1/p2, p3, UUID fstab, 80/20 reserve, guard, and installed boot properties
using `/dev/nvme0n1` and `/dev/nvme0n1pN` names.

## 4. Two Standard Sysupgrade Cycles

Use one compatible installation from the previous sections.

1. Create recognizable non-secret UCI values and a sentinel file on
   `/mnt/data`; record partition starts, sizes, PARTUUIDs, and the p3 UUID.
2. Copy the exact candidate target `.img.gz` to a local path such as `/tmp`.
   The guard intentionally rejects remote image URLs.
3. Confirm `sysupgrade -T IMAGE` succeeds. Confirm `sysupgrade -T -p IMAGE`
   and `sysupgrade -T -n IMAGE` are rejected before any write.
4. Run `sysupgrade IMAGE` and allow the machine to reboot by itself.
5. Verify the system boots, the UCI values and sentinel remain, p3 is mounted,
   all recorded geometry/identifiers are unchanged, and the wrapper is active.
6. Repeat the preflight and real `sysupgrade` once more, then repeat every
   post-boot check. This proves guard restoration after the first upgrade.

Do not mark this gate passed if either cycle requires a manual power cycle.

## 5. Hellforge Safe Upgrade

Use the compatible installation on the other physical device.

1. Create a different non-secret UCI marker and sentinel file on `/mnt/data`;
   record p1/p2/p3 geometry, PARTUUIDs, p3 UUID, and filesystem label.
2. Boot the candidate ISO, select the disk, and choose
   **Hellforge Safe Upgrade** with **Configuration only**.
3. Confirm review states that the partition table and data partitions are
   preserved and only system partitions 1 and 2 are replaced.
4. Enter the exact `UPGRADE /dev/...` phrase and complete the upgrade.
5. Boot the disk and verify the UCI marker, sentinel, p1/p2/p3 geometry,
   identifiers, p3 mount, storage metadata, and sysupgrade wrapper.

## 6. Existing OpenWrt Rescue And Reinstall

1. Boot an ext4 OpenWrt installation and set recognizable non-secret LAN/WAN
   and hostname values. Reboot once and confirm they work.
2. Boot the candidate ISO, select that disk, and confirm its OpenWrt version
   and ext4 root are detected.
3. Choose **Rescue and reinstall**, **Configuration only**, and keep the
   rescued network configuration. Select any reviewed storage profile.
4. Confirm review shows a RAM snapshot hash, source/target versions, restore
   policy, network policy, and target storage geometry.
5. Install and boot. Verify hostname and LAN/WAN UCI values. Package inventory
   must remain informational; packages must not be silently installed.

## 7. Pre-ERASE Power-cycle Gate

1. Add another non-secret UCI marker to the source OpenWrt.
2. Boot the ISO and continue rescue until review confirms a validated snapshot
   is in RAM. Do not enter the exact erase phrase.
3. Cancel or power the machine off.
4. Boot the existing disk and verify partition geometry, filesystems, and the
   added UCI value are unchanged.

## 8. Generate And Verify The Report

Run the no-write hardware-test flow once more on the unchanged clean
pre-candidate, then run:

```sh
owrt-hardware-report
```

Answer `pass` only for checks actually completed above. Preserve
`/tmp/owrt-hardware-report.txt` before rebooting the RAM-root installer. On the
build host first verify that the report names the exact current manifest. Then
freeze that unchanged artifact, commit only the generated metadata, and run
the release gate:

```sh
./scripts/verify-physical-report.sh \
  /path/to/owrt-hardware-report.txt output/manifest.json
make freeze-candidate VERSION=v1.0-alpha.N
git add release/v1.0-alpha.N-candidate.env
git commit -m "Freeze v1.0-alpha.N candidate"
make release-gate \
  CANDIDATE=release/v1.0-alpha.N-candidate.env \
  REPORT=/path/to/owrt-hardware-report.txt
```

No rebuild is allowed between report generation, freeze, and release gate.

Schema 4 requires all of these storage/upgrade results:

```text
manual_storage_rescue_navigation=pass
manual_sata_compatible_layout_and_boot=pass
manual_nvme_compatible_layout_and_boot=pass
manual_standard_sysupgrade_two_cycles=pass
manual_safe_upgrade_preserves_data=pass
manual_rescue_restore=pass
manual_pre_erase_power_cycle_no_change=pass
physical_flow_result=pass
```

It also requires these automatically generated artifact identity fields to
match `output/manifest.json` exactly:

```text
artifact_manifest_sha256=<64 lowercase hex>
artifact_manifest_version=v1.0-alpha.N
artifact_build_commit=<40 lowercase hex>
artifact_build_dirty=false
artifact_payload_sha256=<64 lowercase hex>
artifact_identity_valid=yes
```

The wired USB mouse, keyboard, exact-prompt cleanup, dry-run, and runtime
cleanup gates remain mandatory. Do not include serial numbers, MAC addresses,
public IP addresses, passwords, private configuration, or raw logs in the
report.
