# Краткий итог работ

Дата фиксации: 2026-08-12.

## Актуальное состояние

- Локальная папка проекта: `/home/w0w/owrt_installer`.
- GitHub repository: `https://github.com/woffko/openwrt-installer`.
- Git remote: `origin https://github.com/woffko/openwrt-installer.git`.
- Основная ветка: `main`.
- Текущий commit: см. `git log -1 --oneline`.
- Последняя функциональная правка: structured Hellforge network forms.
- Последний опубликованный release: `v1.0-alpha.1`.
- Release URL: `https://github.com/woffko/openwrt-installer/releases/tag/v1.0-alpha.1`.
- Старый release `v1.0-alpha` оставлен без изменений и уже не является актуальным.
- Новый Hellforge ISO собран локально; для публикации нужен отдельный следующий alpha tag, старые release assets не двигать.
- Project Memory зарегистрирована с ключом `woffko/openwrt-installer`; test secrets выключены.
- Локальная памятка с credential-путями: `LOCAL_CONTEXT.md`; файл намеренно добавлен в `.gitignore`.
- План редизайна TUI: `UI_REDESIGN_PLAN.md` (`OpenWrt Hellforge Installer`, ANSI-first, optional `dialog`/mouse later).
- Реализована первая итерация Hellforge TUI: добавлен `files-installer/usr/libexec/owrt-installer-ui`, `OWRT_UI_MODE=line|ansi|auto`, ANSI frame/menu/review/confirm/install-stage screens и line fallback.
- Network wizard теперь использует form-aware prompt screens для LAN IPv4, PPPoE и static WAN settings: на экране показываются context, example, current/default и error zone.

## Что сделано

- Создан новый проект OpenWrt installer в `/home/w0w/owrt_installer`.
- GitHub repository: `https://github.com/woffko/openwrt-installer`.
- База сборки: официальный OpenWrt ImageBuilder `25.12.4` для `x86_64`.
- Собран target-образ OpenWrt для установки на диск.
- Собран live installer-образ с командой `owrt-install`.
- Добавлена сборка BIOS/UEFI hybrid ISO с RAM-root initramfs.
- Добавлены локальные host tools для ISO: `xorriso`, `cpio` и зависимости через `make iso-host-tools`.

## Установщик

`owrt-install` делает следующее:

- проверяет SHA-256 и gzip payload перед записью;
- показывает доступные диски;
- блокирует removable-диски без `--allow-removable`;
- блокирует detected live boot disk;
- требует точное подтверждение `ERASE /dev/...`;
- пишет target image на выбранный диск;
- расширяет второй раздел и ext4 rootfs на весь диск;
- пишет `/etc/owrt-installer/interface-map`;
- на первом boot установленная система настраивает `br-lan`, WAN, DHCP, DHCPv6, firewall и NAT.

## Исправление network wizard

Исправлена логика выбора интерфейсов:

- сначала явно выбирается LAN;
- если интерфейсов ровно два, второй автоматически назначается WAN;
- если интерфейсов больше двух, для WAN показывается список без выбранного LAN;
- исправлена проблема, когда prompt выбора интерфейса не отображался на экране.
- добавлены цветные секции wizard;
- на интерактивной TTY добавлен выбор из списка стрелками Up/Down и Enter;
- для pipe/скриптов сохранен fallback на ввод номера.

## Новые network settings

В установщике добавлены вопросы:

- LAN IPv4/CIDR, например `192.168.1.1/24`;
- WAN mode: DHCP, PPPoE, static IPv4 или disabled;
- PPPoE username/password;
- static WAN IPv4/CIDR, gateway и DNS;
- WAN6 DHCPv6 или disabled.

Эти параметры сохраняются в `/etc/owrt-installer/interface-map` и применяются на первом boot установленной системы.

Последняя итерация wizard:

- LAN IPv4/CIDR, PPPoE username/password, static WAN IPv4/gateway/DNS переведены на structured form screens;
- ошибки валидации возвращают только к текущему полю и не сбрасывают весь wizard;
- неверный gateway/DNS больше не становится новым default после ошибки;
- static WAN DNS теперь проверяется как список IPv4 адресов;
- WAN IPv6 menu явно показывает только `DHCPv6 / Prefix Delegation` и `Disabled / no WAN IPv6`;
- для PPPoE добавлена note, что отдельного PPPoE IPv6 режима нет; IPv6 выбирается как DHCPv6/PD поверх WAN-сессии при поддержке ISP;
- PPPoE password не выводится в review screen.

## Автозапуск

Live installer теперь запускает `owrt-install --autostart` автоматически через `/etc/inittab` на `tty1`, чтобы установщик открывался на видимой локальной консоли. Перед стартом wrapper приглушает информационные kernel-сообщения, ждет стабилизации block/net устройств и очищает экран. Serial-консоли `ttyS0` и `hvc0` остаются обычным login.

## Hybrid ISO

Создан артефакт:

```text
output/openwrt-x86-64-installer-hybrid.iso
```

ISO содержит:

- BIOS boot через GRUB;
- UEFI boot через EFI System Partition;
- GPT layout;
- RAM-root initramfs с актуальным `owrt-install`;
- тот же target payload, что и raw installer.

`make iso` теперь зависит от `installer`, чтобы изменения в `files-installer/` всегда попадали в ISO.

## Итоговые артефакты

```text
output/openwrt-x86-64-target.img.gz
output/openwrt-x86-64-installer.img.gz
output/openwrt-x86-64-installer-hybrid.iso
output/manifest.json
output/sha256sums.txt
```

SHA-256:

```text
18036cf685520a7328378eac6af15b12fd84eab0cc814f8b8510c7893312fbd6  openwrt-x86-64-target.img.gz
e7b64af24c6b36dc88be71988868d3818b0e271ba45ef20def9feaa5930a4589  openwrt-x86-64-installer.img.gz
c7bf2e45910184f9402e50ddbb65e23947a1e3cebd7fb3895520a690f20cef1b  openwrt-x86-64-installer-hybrid.iso
ac898d815376f7e4a35c06a0fcba465bea16892bdadf03d4357a79b05e22c26e  manifest.json
```

## Проверки

Выполнено:

- `make syntax-check`;
- `make shellcheck`;
- проверка `sha256sums.txt`;
- проверка ISO через `fdisk` и `xorriso`;
- проверка, что `owrt-install` и `owrt-installer-ui` внутри ISO/initramfs совпадают с исходными файлами;
- smoke-тест логики выбора LAN/WAN на 2 и 3 интерфейсах;
- smoke-тест DHCP/static WAN wizard и CIDR-конвертации;
- локальная распаковка QEMU/OVMF в `build/qemu-local`;
- BIOS ISO boot smoke-test в QEMU: OpenWrt загрузился до serial console;
- UEFI ISO boot smoke-test в QEMU: OpenWrt загрузился до serial console.

Для первой Hellforge TUI итерации дополнительно выполнено:

- `make syntax-check`;
- `OWRT_UI_MODE=line TERM=dumb owrt-install --help`;
- `OWRT_UI_MODE=line TERM=dumb owrt-install --list-disks`;
- `OWRT_UI_MODE=line TERM=dumb owrt-install --list-nics`;
- `OWRT_UI_MODE=line TERM=dumb owrt-install --dry-run`;
- synthetic TTY smoke для ANSI arrow menu;
- synthetic TTY smoke для ANSI review/confirm/install-stage screens;
- `make shellcheck` через локальный `build/host-tools/usr/bin/shellcheck`;
- line smoke для LAN form error retry;
- line smoke для static WAN invalid IP/gateway/DNS retry и WAN6 disabled;
- line smoke для PPPoE + DHCPv6/PD с проверкой, что password не появляется в review;
- ANSI pseudo-TTY smoke для LAN form error screen через `script`;
- сборка нового hybrid ISO после Hellforge TUI и structured network forms;
- проверка `sha256sum -c output/sha256sums.txt`;
- проверка initramfs через `cpio`, что внутри есть `usr/sbin/owrt-install` и `usr/libexec/owrt-installer-ui`;
- проверка строк structured forms внутри initramfs: `LAN IPv4 settings`, `Static WAN IPv4 settings`, `Disabled / no WAN IPv6`, note про отсутствие отдельного PPPoE IPv6 режима;
- BIOS ISO boot smoke-test в QEMU: El Torito BIOS -> GRUB -> kernel -> initramfs -> OpenWrt console, лог `build/qemu-iso-smoke/bios-iso.log`;
- UEFI ISO boot smoke-test в QEMU: OVMF -> UEFI DVD -> GRUB -> EFI stub -> kernel -> initramfs -> OpenWrt console, лог `build/qemu-iso-smoke/uefi-iso.log`;
- на serial видно, что live installer управляется `/etc/inittab` на `tty1`; полноэкранный TUI проверяется на локальной VGA/tty1, а serial остается fallback/login каналом.

## Как пользоваться

Записать ISO на USB через Rufus, balenaEtcher, Ventoy или `dd` и загрузиться с него. На локальной консоли `tty1` установщик стартует автоматически.

Если автозапуск не сработал или нужен ручной запуск, выполнить:

```sh
owrt-install
```
