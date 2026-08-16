# Physical x86 Mouse Acceptance

This procedure validates the experimental local-console mouse path on bare
metal without allowing the installer to write a disk.

The mouse path was also checked on a real machine for published
`v1.0-alpha.10`. This document remains useful for mouse diagnostics, but its
old schema 2 report is no longer sufficient for a new release. Current
storage/rescue candidates must follow
[PHYSICAL_X86_STORAGE_RESCUE_TEST.md](PHYSICAL_X86_STORAGE_RESCUE_TEST.md) and
produce one combined schema 4 report.

## Historical Release Candidate

The previous physical alpha candidate was:

```text
installer_version=v1.0-alpha.8
runtime_commit=964fed6
iso_sha256=f1131d7587d49b5accf0e1e6b96fc378114fd1f9293a7e1e1a0e5dc1772a22e5
```

It is retained only as historical evidence. Runtime and image changes after
that build invalidated it, so it must not be used for a new physical report or
release.

## Historical Alpha.9 Candidate

The historical alpha.9 candidate was:

```text
installer_version=v1.0-alpha.9
runtime_commit=8e8593c5891ff69f98a9ee3ef5fcdd23444d2b51
candidate_metadata=release/v1.0-alpha.9-candidate.env
iso_sha256=2b570a2e5747b0a9f2cd46c8252059dd64f101d35c0e14c06fdb69402cffd851
manifest_sha256=2d957a424664e7d6a5f75b0646e226289446d13205c12db83e0a32db4c26bd15
```

On 2026-08-15 this exact runtime passed `make smoke`, three repeated USB
relative-mouse runs, the full USB/PS2/tablet mouse matrix, focused
configuration-import install/boot, and the complete BIOS/UEFI ISO matrix.
Those virtual-machine results do not close the separate bare-metal gate. Any
later runtime or ISO change invalidates this candidate. Current workflow builds
and identifies a clean pre-candidate in the physical report, then freezes that
same unchanged artifact only after the report passes.

## Safety

Use a disposable test machine and a non-essential target disk. The temporary
GRUB kernel edit below forces `--dry-run`, and the QEMU gate verifies
byte-for-byte target disk immutability, but physical testing must still avoid
the only copy of any important data.

Verify the ISO before writing it to USB:

```sh
cd output
sha256sum -c sha256sums.txt
```

The hashes above are retained only to identify the old alpha.9 artifact. Do
not use either historical block for a current release gate.

## Required Hardware

- one x86_64 machine with a local VGA/HDMI/DisplayPort console;
- a USB keyboard;
- a relative USB HID mouse or USB receiver;
- at least one target disk visible to the installer;
- at least two network interfaces, physical or USB, for the complete wizard.

A wired USB HID run closes only the mouse portion of the current physical
gate. SATA/NVMe compatible layouts, standard sysupgrade, Safe Upgrade, rescue,
and pre-ERASE power-cycle results remain separate required checks.

## Procedure

1. Highlight **OpenWrt x86 Installer** in GRUB and press `e`. On the line that
   starts with `linux`, append `owrt.hardware-test=1` without removing
   `owrt.mouse=1`, then boot with Ctrl+X or F10. Do not boot the unmodified
   installer for this acceptance run.
2. Confirm that the welcome screen says `HARDWARE TEST / DRY RUN`.
3. Use the mouse to select the target disk and activate the `OK` button.
4. Use clicks to select LAN, WAN, WAN mode, and WAN6 mode. Use the wheel on at
   least one list with multiple items; record `skipped` only when no suitable
   list exists.
5. Complete at least one screen with Up/Down and Enter to prove keyboard
   fallback remains available.
6. Continue through review. The final screen must say `SAFE DRY RUN`.
7. At the exact `ERASE /dev/...` prompt, verify that mouse input no longer
   acts on the console. Enter the exact phrase with the keyboard. This is safe
   only when the edited kernel line contains `owrt.hardware-test=1`.
8. Confirm the `Dry run complete` dialog explicitly states that no disk
   changes were made, then close it with Enter.
9. At the OpenWrt console, run:

   ```sh
   owrt-hardware-report
   ```

10. Answer each manual gate with `p`, `f`, or `s`. For a mouse-only diagnostic,
    mark unperformed storage checks as skipped; the final result will correctly
    remain incomplete. Preserve `/tmp/owrt-hardware-report.txt` before reboot.
11. For a release, complete the storage/rescue procedure and then validate the
    combined report on the build host:

    ```sh
    ./scripts/verify-physical-report.sh /path/to/owrt-hardware-report.txt
    make release-gate \
      CANDIDATE=release/v1.0-alpha.N-candidate.env \
      REPORT=/path/to/owrt-hardware-report.txt
    ```

    The second command also verifies the frozen runtime commit, ISO SHA-256,
    sidecar and ISO-embedded manifest, build provenance, and absence of later
    tracked, staged, untracked, or unexpected ignored runtime changes.

## Mouse Subcriteria

The report must contain:

```text
kernel_mouse_flag=yes
kernel_hardware_test_flag=yes
mouse_started=yes
mouse_stopped=yes
dry_run_complete=yes
runtime_cleanup=yes
manual_pointer_move=pass
manual_click=pass
manual_keyboard=pass
manual_exact_prompt_mouse_stop=pass
pointer_connection=usb-wired
relative_pointer_count=1
```

`relative_pointer_count` may be greater than one. `manual_wheel=skipped` is
acceptable only when the available lists cannot scroll; otherwise it must be
`pass`. The report records this exception as
`manual_wheel_skip_reason=no-scrollable-list`. Any `fail`, missing automatic
`yes`, unknown connection type, or remaining GPM runtime file keeps the
physical gate open. The verifier additionally requires
`pointer_connection=usb-wired`; receiver and PS/2 reports remain useful as
secondary-platform evidence. `physical_flow_result=pass` is emitted only when
the schema 4 storage/upgrade/rescue checks also pass. Historical schema 2 and
3 reports are intentionally rejected by the current release gate.

Record the machine model, firmware mode, and pointer connection type next to
the report after reviewing them. Do not include DMI serial numbers, disk
serials, MAC addresses, public IP addresses, raw configuration, or an
unsanitized `dmesg` dump.

## Failure Triage

The generated report includes kernel flags, safe input bus/vendor/product IDs,
package versions, relative-pointer count, installer lifecycle markers, and
runtime cleanup state. If it fails, also preserve only these bounded outputs:

```sh
grep -E 'owrt-installer-mouse|Dry run' /tmp/owrt-installer.log
ls -l /dev/input/mice /dev/input/event* /dev/gpmctl /var/run/gpm.pid 2>&1
ps w | grep '[g]pm'
```

Inspect broader logs locally, but sanitize hardware serials, network
identifiers, credentials, and unrelated boot data before sharing them.
