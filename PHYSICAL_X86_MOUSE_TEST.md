# Physical x86 Mouse Acceptance

This procedure validates the experimental local-console mouse path on bare
metal without allowing the installer to write a disk.

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
relative_pointer_count=1
```

`relative_pointer_count` may be greater than one. `manual_wheel=skipped` is
acceptable only when the available lists cannot scroll; otherwise it must be
`pass`. Any `fail`, missing automatic `yes`, or remaining GPM runtime file
keeps the physical gate open.

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
