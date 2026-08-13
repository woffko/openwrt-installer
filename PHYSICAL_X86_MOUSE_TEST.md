# Physical x86 Mouse Acceptance

This procedure validates the experimental local-console mouse path on bare
metal without allowing the installer to write a disk.

## Release Candidate

The physical alpha gate applies only to this frozen candidate:

```text
installer_version=v1.0-alpha.8
runtime_commit=964fed6
iso_sha256=f1131d7587d49b5accf0e1e6b96fc378114fd1f9293a7e1e1a0e5dc1772a22e5
```

Any runtime or image change invalidates the result and requires a rebuilt ISO
and a new physical pass. The eventual release asset must be byte-identical to
this candidate.

## Safety

Use a disposable test machine and a non-essential target disk. The dedicated
GRUB entry forces `--dry-run`, and the QEMU gate verifies byte-for-byte target
disk immutability, but physical testing must still avoid the only copy of any
important data.

Verify the ISO before writing it to USB:

```sh
cd output
sha256sum -c sha256sums.txt
```

The hybrid ISO line must match the candidate SHA-256 above.

## Required Hardware

- one x86_64 machine with a local VGA/HDMI/DisplayPort console;
- a USB keyboard;
- a relative USB HID mouse or USB receiver;
- at least one target disk visible to the installer;
- at least two network interfaces, physical or USB, for the complete wizard.

One successful wired USB HID run closes the physical gate for an opt-in alpha
release. Enabling mouse input by default additionally requires a second
platform class, preferably a laptop with an internal PS/2-compatible pointer
or a different USB receiver/controller.

## Procedure

1. Boot the hybrid ISO and select **Mouse hardware test (no disk writes)** in
   GRUB. Do not edit the normal installer entry.
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
   only in the dedicated hardware-test boot mode.
8. Confirm the `Dry run complete` dialog explicitly states that no disk
   changes were made, then close it with Enter.
9. At the OpenWrt console, run:

   ```sh
   owrt-hardware-report
   ```

10. Answer each manual gate with `p`, `f`, or `s`. Preserve the resulting
    `/tmp/owrt-hardware-report.txt` before rebooting the RAM-root system.
11. On the build host, validate the preserved report before release:

    ```sh
    ./scripts/verify-physical-report.sh /path/to/owrt-hardware-report.txt
    ```

## Pass Criteria

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
physical_flow_result=pass
```

`relative_pointer_count` may be greater than one. `manual_wheel=skipped` is
acceptable only when the available lists cannot scroll; otherwise it must be
`pass`. The report records this exception as
`manual_wheel_skip_reason=no-scrollable-list`. Any `fail`, missing automatic
`yes`, unknown connection type, or remaining GPM runtime file keeps the
physical gate open. The alpha gate verifier additionally requires
`pointer_connection=usb-wired`; receiver and PS/2 reports remain useful as
secondary-platform evidence but cannot close the first gate.

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
ls -l /dev/input/event* /dev/gpmctl /var/run/gpm.pid 2>&1
ps w | grep '[g]pm'
```

Inspect broader logs locally, but sanitize hardware serials, network
identifiers, credentials, and unrelated boot data before sharing them.
