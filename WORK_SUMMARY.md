# Краткий итог работ

Дата фиксации: 2026-08-13.

## Актуальное состояние

- Локальная папка проекта: `/home/w0w/owrt_installer`.
- GitHub repository: `https://github.com/woffko/openwrt-installer`.
- Git remote: `origin https://github.com/woffko/openwrt-installer.git`.
- Основная ветка: `main`.
- Текущий commit: см. `git log -1 --oneline`.
- Последняя опубликованная функциональная версия: обязательный `pv`, честный byte-percent записи payload, раздельный контроль `gzip`/`pv`/`dd`, cleanup FIFO/processes и полный QEMU install+boot smoke; release runtime `v1.0-alpha.7`.
- Текущий локальный release candidate: `v1.0-alpha.8`, experimental local VGA mouse через hardened GPM/evdev; выключена по умолчанию до physical x86 gate.
- Последний опубликованный release: `v1.0-alpha.7`.
- Release URL: `https://github.com/woffko/openwrt-installer/releases/tag/v1.0-alpha.7`.
- Старый release `v1.0-alpha` оставлен без изменений и уже не является актуальным.
- Старые releases `v1.0-alpha.1`...`v1.0-alpha.6` оставлены без изменений; актуальный Hellforge ISO публикуется отдельным alpha tag.
- Опубликованный `v1.0-alpha.7` ISO содержит обязательные `whiptail` и `pv`; SHA-256: `89f9e2c89df7fe27f882d1d2db7114caefff226ad840b70b92b1205458ddfa7c`.
- Предыдущий `v1.0-alpha.8-dev` ISO имел SHA-256 `1574d904d60d7c09fca76961a81e17610ac8c4d5c406b3d05a33c97e16ed19a0`; после заморозки runtime как `v1.0-alpha.8` release candidate должен быть полностью пересобран и повторно проверен до physical x86 gate.
- Project Memory зарегистрирована с ключом `woffko/openwrt-installer`; test secrets выключены.
- Локальная памятка с credential-путями: `LOCAL_CONTEXT.md`; файл намеренно добавлен в `.gitignore`.
- План редизайна TUI: `UI_REDESIGN_PLAN.md` (`OpenWrt Hellforge Installer`, packaged `whiptail` на local console, ANSI SGR mouse для terminal emulators, line fallback и optional `dialog`).
- Local VGA mouse prototype: pinned SDK packages `libnewt`/`whiptail`, daemon-only `gpm-daemon`, relative evdev selection, private `0600` socket и отдельный `make mouse-qemu-smoke`.
- QEMU local-mouse matrix пройдена: USB click, PS/2, absolute-only tablet rejection, daemon crash keyboard fallback, cleanup stale runtime-файлов внутри OpenWrt и cleanup до exact `ERASE`; публикация/default ждут physical x86 test.
- Для physical gate добавлен отдельный GRUB-пункт `Mouse hardware test (no disk writes)`: kernel flag принудительно включает `--dry-run`, UI явно показывает safe mode, а `owrt-hardware-report` создает ограниченный отчет без сетевых и аппаратных серийных идентификаторов.
- Physical report schema v2 фиксирует безопасный enum подключения, обязательные ручные проверки и итог `physical_flow_result`; `scripts/verify-physical-report.sh` принимает первый alpha gate только для полного wired USB HID pass и отвергает receiver/PS2 или неполный отчет.
- Реальный GRUB-путь hardware-test проверен в QEMU; полный wizard до exact `ERASE` завершился в dry-run, GPM был остановлен перед подтверждением, а SHA-256 всего target disk до и после совпал.
- На предыдущем `v1.0-alpha.8-dev` ISO прошли `make smoke`, `make mouse-qemu-smoke`, BIOS/UEFI/VGA boot и полный install-to-disk/installed-system boot через `make iso-smoke`; те же gates обязательны для замороженного `v1.0-alpha.8` candidate.
- Реализованы `OWRT_UI_MODE=auto|line|ansi|whiptail|curses|dialog`, общий curses adapter и Hellforge frame/menu/review/confirm/install-stage screens.
- Network wizard теперь использует form-aware prompt screens для LAN IPv4, PPPoE и static WAN settings: на экране показываются context, example, current/default и error zone.
- `whiptail 0.52.24` добавлен как обязательный официальный package; local `TERM=linux` console использует его автоматически. `curses` выбирает работающий `dialog`, затем `whiptail`, затем ANSI.
- Пакет `dialog` в текущем OpenWrt `25.12.4` feed недоступен и остается optional; SSH/xterm auto mode использует ANSI для native SGR mouse.
- В ANSI menus добавлена zero-dependency мышь через SGR mouse protocol: direct click выбирает видимый пункт, wheel меняет highlight, а `OWRT_UI_NO_MOUSE=1` отключает tracking. Функция включается только для SSH/xterm-compatible terminals; serial остается keyboard-only, а `TERM=linux` использует клавиатуру по умолчанию и включает experimental local mouse только явным флагом.
- Network forms теперь поддерживают пошаговый Back: ANSI `Esc`, dialog Cancel и line-mode `!back`; WAN/WAN6 menus имеют явные Back items. Уже введенные значения сохраняются при возврате, а credentials/settings невыбранного WAN protocol очищаются до review.
- Перед финальным destructive confirmation добавлен safe review action menu: continue к точному `ERASE /dev/...`, edit LAN/WAN interfaces and network settings или cancel.
- Для установки на диск добавлен stage progress screen с compact log pane, `/tmp/owrt-installer.log`, тихой записью `dd` в лог и отдельным failure screen с хвостом лога.
- `manifest.json` теперь содержит `payload_uncompressed_size`; установщик логирует распакованный размер payload перед записью.
- `pv 1.9.31` добавлен как обязательный package. Запись payload показывает numeric percent в native curses gauge или ANSI/line renderer; `gzip`, `pv` и `dd` запускаются через отдельные FIFO и проверяются по отдельным PID/status.
- `make iso-smoke` теперь дополнительно проходит весь wizard, пишет образ на одноразовый qcow2, проверяет progress до `100`, загружает установленную систему и читает `/etc/openwrt-installer-release`.

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
fddb0ac61320dcfafc444a4962c679d8e92569446a930bdbde1310ae9206e553  openwrt-x86-64-installer.img.gz
1574d904d60d7c09fca76961a81e17610ac8c4d5c406b3d05a33c97e16ed19a0  openwrt-x86-64-installer-hybrid.iso
f860a72e1e2598748064206a9dd90e5da25df71a41f9319ea73d9e77c783962d  manifest.json
```

## Проверки

Выполнено:

- `make syntax-check`;
- `make shellcheck`;
- проверка `sha256sums.txt`;
- пересборка актуального hybrid ISO через `make iso` после последних UI/runtime изменений;
- проверка ISO через `fdisk` и `xorriso`;
- проверка, что `owrt-install` и `owrt-installer-ui` внутри ISO/initramfs совпадают с исходными файлами;
- запуск встроенного `whiptail` через OpenWrt musl loader: `whiptail (newt): 0.52.24`;
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
- fake runtime smoke для optional `dialog` backend: проверено `mode=dialog`, menu selection, наличие `--mouse` и отключение через `OWRT_UI_NO_MOUSE=1`;
- pseudo-TTY smoke для `OWRT_UI_MODE=dialog` без runtime package: fallback уходит в `mode=ansi`;
- line smoke для review action: `Continue -> ERASE` и `Edit network -> repeated review -> Continue -> ERASE`;
- сборка нового hybrid ISO после Hellforge TUI, structured network forms, optional dialog backend hook и review action loop;
- проверка `sha256sum -c output/sha256sums.txt`;
- проверка ISO layout после последней сборки через `fdisk` и `xorriso -report_el_torito`;
- проверка initramfs через `cpio`, что внутри есть `usr/sbin/owrt-install` и `usr/libexec/owrt-installer-ui`;
- проверка строк structured forms внутри initramfs: `LAN IPv4 settings`, `Static WAN IPv4 settings`, `Disabled / no WAN IPv6`, note про отсутствие отдельного PPPoE IPv6 режима;
- проверка dialog hook строк внутри initramfs: `ui_dialog_active`, `OWRT_UI_NO_MOUSE`, `dialog --stdout`;
- проверка review action loop внутри initramfs: `review_and_confirm`, `Review action`, `No disk write starts`;
- line smoke для нового install-stage/failure screen с хвостом `/tmp/owrt-installer-ui-smoke.log`;
- ANSI pseudo-TTY smoke для нового progress bar и compact log pane;
- проверка manifest поля `payload_uncompressed_size` в `output/manifest.json` и initramfs;
- проверка, что `dd status=progress` больше не используется в runtime installer path;
- добавлен и пройден быстрый `make ui-smoke`: line menu/stage/failure, ANSI stage через pseudo-TTY, dialog fallback mode и terminal-size checks 80x25/100x30/79x19;
- добавлен и пройден ANSI snapshot smoke внутри `make ui-smoke`: render menu в pseudo-TTY, strip ANSI/CR, проверка header/steps/items/footer без escape-мусора;
- добавлен `menu_warning` и красная warning-секция на выборе диска; snapshot smoke проверяет текст `WARNING: selected disk will be erased after final confirmation`;
- auto-mode ANSI TUI теперь включается только с терминалом минимум `80x24`; `make ui-smoke` проверяет `80x24` как TUI и `80x23` как line fallback;
- добавлен и пройден Ctrl+C cleanup smoke внутри `make ui-smoke`: ANSI menu в pseudo-TTY получает interrupt byte, выходит с кодом 130 и возвращает cursor-visible state;
- добавлен и пройден Esc cancel smoke внутри `make ui-smoke`: одиночный Esc в ANSI menu отменяет выбор без случайного Enter/selection;
- добавлен и пройден native ANSI mouse smoke внутри `make ui-smoke`: pseudo-TTY получает SGR click по второй строке, выбирает второй пункт и подтверждает enable/disable `1000`/`1006` tracking;
- добавлен и пройден безопасный `make install-flow-smoke`: source-only проверка CLI parsing, `--dry-run`, `--skip-network-wizard` и запрет destructive write path;
- добавлен и пройден быстрый `make smoke`: syntax-check, shellcheck, ui-smoke и install-flow-smoke без пересборки ISO/QEMU;
- добавлен и пройден `hardware-report-smoke`: проверка privacy-safe отчета, kernel flags, lifecycle markers, relative evdev inventory и cleanup state;
- добавлен автоматический `make iso-smoke`: bounded QEMU BIOS/UEFI/VGA boot текущего hybrid ISO с проверкой GRUB, kernel/initramfs, OpenWrt console, backend/ready markers и framebuffer;
- `make iso-smoke` выбирает второй GRUB entry и подтверждает `owrt.mouse=1`, `owrt.hardware-test=1`, forced dry-run и отсутствие write-progress marker;
- BIOS ISO boot smoke-test в QEMU: El Torito BIOS -> GRUB -> kernel -> initramfs -> OpenWrt console, лог `build/qemu-iso-smoke/bios-iso.log`;
- UEFI ISO boot smoke-test в QEMU: OVMF -> UEFI DVD -> GRUB -> EFI stub -> kernel -> initramfs -> OpenWrt console, лог `build/qemu-iso-smoke/uefi-iso.log`;
- VGA QEMU smoke-test дождался target-disk menu на `tty1`, подтвердил `OWRT_INSTALLER_UI_BACKEND=whiptail` и сохранил непустой framebuffer `build/qemu-iso-smoke/vga-installer.ppm`;
- QEMU install smoke автоматически прошел disk/LAN/WAN/WAN6/review/erase flow, увидел `OWRT_INSTALLER_WRITE_PROGRESS=100`, загрузил записанный qcow2 и подтвердил предыдущий `installer_version=v1.0-alpha.8-dev`, `installed_by=openwrt-x86-installer`, `target_disk=/dev/vda`;
- для предыдущего локального `v1.0-alpha.8-dev` повторно пройдены BIOS/UEFI/VGA и полный install smoke; установленная система подтвердила runtime marker, а local-mouse matrix отдельно проверила USB/PS2/fallback/cleanup;
- `make smoke` и единый `make iso-smoke` прошли перед публикацией; checksum manifest, GPT, BIOS/UEFI El Torito entries, source/initramfs compare и embedded `pv 1.9.31` проверены;
- real pseudo-TTY smoke управляет настоящим host `whiptail`: Down/Enter, input edit, Esc/Back, password hiding, theme, shell-metacharacter safety и backend precedence/fallback;
- на serial видно, что live installer управляется `/etc/inittab` на `tty1`; serial остается fallback/login каналом.

## Как пользоваться

Записать ISO на USB через Rufus, balenaEtcher, Ventoy или `dd` и загрузиться с него. На локальной консоли `tty1` установщик стартует автоматически.

Если автозапуск не сработал или нужен ручной запуск, выполнить:

```sh
owrt-install
```
