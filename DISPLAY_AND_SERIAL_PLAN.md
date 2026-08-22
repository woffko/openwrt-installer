# Display, Logo, And Serial Console Plan

Дата: 2026-08-22.

База: `v1.0-beta.2-dev`. Эта итерация становится `v1.0-beta.3-dev` и не
изменяет опубликованный `v1.0-beta.1` release.

## Требования

1. Исправить classic OpenWrt ASCII logo: весь block центрируется один раз по
   максимальной ширине, каждая строка сохраняет исходную колонку и пробелы.
2. Main BIOS/UEFI GRUB entry предпочитает `1024x768`, затем `800x600`, `auto`
   и text fallback. Linux framebuffer сохраняет выбранный mode.
3. Failsafe остается text-oriented и не зависит от graphics mode.
4. Один installer process может владеть диском. VGA, `ttyS0` и `hvc0` никогда
   не запускают независимые installer sessions.
5. Normal entry использует first-input arbitration: Enter на VGA/serial/hvc
   получает ownership; без ввода VGA становится owner через 10 секунд.
6. Отдельный GRUB serial entry немедленно назначает owner `ttyS0`, запускает
   framebuffer-independent line UI без GPM и сохраняет `115200 8N1`.
7. Проигравшие TTY показывают owner и bounded mirror `/tmp/owrt-installer.log`.
   Они не принимают destructive input и после завершения переходят в login.
8. Owner определяется атомарным `mkdir`; lock сохраняется до reboot даже после
   выхода installer, поэтому respawn не может начать вторую установку.
9. Kernel console остается dual (`tty1` + `ttyS0`). Installer markers доступны
   на serial независимо от выбранного UI owner.

## Graphics Contract

- В ISO включается tracked ASCII-only PF2 font, созданный из DejaVu Sans Mono.
- GRUB core содержит `font`, `gfxterm`, `all_video`, `video`, BIOS VBE и UEFI
  GOP modules.
- Preferred list:
  `1024x768x32,1024x768,800x600x32,800x600,auto`.
- Если font или graphics terminal недоступны, GRUB продолжает с
  `terminal_output console serial`; boot не блокируется.
- Runtime serial marker записывает фактический `/sys/class/graphics/fb0/virtual_size`
  либо `text`, чтобы QEMU проверял результат, а не только GRUB config.

## Broker Contract

- State directory: `/tmp/owrt-installer-owner.lock`.
- Data-only files: `tty`, `pid`, `state`, `exit-status`.
- States: `claiming`, `settling`, `running`, `finished`.
- Exact owner values: `tty1`, `ttyS0`, `hvc0`.
- `owrt.console=ttyS0|hvc0|tty1` forces one owner.
- Normal dual mode accepts only an empty Enter line or literal `INSTALL`;
  arbitrary serial noise does not claim ownership.
- Mirror checks owner PID and state. A dead owner releases no second install;
  loser reports the failure and enters login.
- `OWRT_INSTALL_NO_AUTOSTART=1` bypasses arbitration and opens login.

## Acceptance

1. Fast fixture proves atomic single winner, VGA timeout, serial Enter, forced
   serial, noise rejection, persistent lock and loser mirror behavior.
2. Logo patch applies/compiles; block width and common X origin are asserted.
3. BIOS QEMU verifies preferred framebuffer or documented text fallback.
4. UEFI QEMU verifies GOP framebuffer or documented text fallback.
5. `-nographic` forced-serial QEMU drives the real line wizard through
   hardware-test dry-run and verifies target disk immutability.
6. Dual-console QEMU proves only one owner marker and no duplicate installer.
7. Full mouse and ISO regression matrices pass.
8. VMware screenshot confirms corrected logo alignment and negotiated display
   size; no target write is performed.
