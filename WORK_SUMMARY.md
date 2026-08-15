# Краткий итог работ

Дата фиксации: 2026-08-15.

## Alpha.11 Storage/Rescue Development

- Опубликованный prerelease: `v1.0-alpha.10`,
  `https://github.com/woffko/openwrt-installer/releases/tag/v1.0-alpha.10`.
- Текущий frozen candidate: `v1.0-alpha.11`; runtime commit `a1009d7`,
  metadata commit `1bce4e8`. Candidate не опубликован.
- Hybrid ISO SHA-256:
  `712f8c20793815b2a9d09d05ac0a3146a4b2985012fea1302875be4c071bd38e`;
  manifest фиксирует `build_dirty=false` и runtime commit `a1009d7`.
- Реализованы `fill`, `image`, 4/8/16/32 GiB presets и custom MiB/GiB rootfs;
  fixed layout оставляет хвост диска неразмеченным.
- MBR/GPT payload inspector считает exact 512-byte sectors и до `ERASE`
  проверяет ext4 superblock/partition invariant. 4 KiB logical-sector disks
  намеренно отклоняются.
- Существующая x86 ext4 OpenWrt обнаруживается только на выбранном диске,
  монтируется `ro,noload,nosuid,nodev,noexec`, а config-only/full snapshot
  полностью копируется и повторно проверяется в RAM до записи target.
- Full rescue удаляет stale installer state, сохраняет regular files и modes,
  копирует hardlinks как независимые files и оставляет package inventory только
  информационным.
- Unknown/SNAPSHOT version relation требует ручного подтверждения; CLI rescue
  его отклоняет. Standard upgrade action является zero-write handoff и не
  запускает `sysupgrade` из live ISO.
- Пройдены full fast smoke, UEFI fill/image/preset/custom install+boot, full
  rescue+boot, zero-write handoff и official OpenWrt `25.12.5` online BIOS/MBR
  и UEFI/GPT install+boot. Дополнительный frozen-ISO matrix проверил AHCI
  `/dev/sda`, NVMe `/dev/nvme0n1`, неизменность второго диска и нулевую запись
  после RAM rescue snapshot при выключении на exact `ERASE` prompt.
- Hardware report обновлен до schema 3. Публикация alpha.11 заблокирована до
  реального SATA+NVMe+rescue+power-cycle отчета по
  `PHYSICAL_X86_STORAGE_RESCUE_TEST.md`.

## Актуальное состояние

- Локальная папка проекта: `/home/w0w/owrt_installer`.
- GitHub repository: `https://github.com/woffko/openwrt-installer`.
- Git remote: `origin https://github.com/woffko/openwrt-installer.git`.
- Основная ветка: `main`.
- Текущий commit: см. `git log -1 --oneline`.
- Последний опубликованный release: `v1.0-alpha.10`.
- Release URL: `https://github.com/woffko/openwrt-installer/releases/tag/v1.0-alpha.10`.
- Текущий development runtime: `v1.0-alpha.11`; clean candidate еще не заморожен.
- `v1.0-alpha.9` candidate и его metadata сохранены как исторические и не
  являются основанием для нового release.
- Старый release `v1.0-alpha` оставлен без изменений и уже не является актуальным.
- Старые releases `v1.0-alpha.1`...`v1.0-alpha.6` оставлены без изменений; актуальный Hellforge ISO публикуется отдельным alpha tag.
- Опубликованный `v1.0-alpha.7` ISO содержит обязательные `whiptail` и `pv`; SHA-256: `89f9e2c89df7fe27f882d1d2db7114caefff226ad840b70b92b1205458ddfa7c`.
- Предыдущий замороженный `v1.0-alpha.8` release-candidate ISO собран из runtime commit `964fed6`; SHA-256: `f1131d7587d49b5accf0e1e6b96fc378114fd1f9293a7e1e1a0e5dc1772a22e5`. Он сохранен как исторический candidate, но не покрывает post-import runtime; для следующего release нужен новый physical pass и новая заморозка.
- Текущий frozen `v1.0-alpha.9` hybrid ISO SHA-256: `2b570a2e5747b0a9f2cd46c8252059dd64f101d35c0e14c06fdb69402cffd851`; manifest SHA-256: `2d957a424664e7d6a5f75b0646e226289446d13205c12db83e0a32db4c26bd15`.
- Project Memory зарегистрирована с ключом `woffko/openwrt-installer`; test secrets выключены.
- Локальная памятка с credential-путями: `LOCAL_CONTEXT.md`; файл намеренно добавлен в `.gitignore`.
- План редизайна TUI: `UI_REDESIGN_PLAN.md` (`OpenWrt Hellforge Installer`, packaged `whiptail` на local console, ANSI SGR mouse для terminal emulators, line fallback и optional `dialog`).
- Local VGA mouse prototype: pinned SDK packages `libnewt`/`whiptail`, daemon-only `gpm-daemon`, stock Linux `mousedev` aggregate `/dev/input/mice`, private `0600` socket и отдельный `make mouse-qemu-smoke`.
- QEMU local-mouse matrix пройдена: USB relative click, PS/2, absolute-only QEMU tablet click через QMP, daemon crash keyboard fallback, cleanup stale runtime-файлов внутри OpenWrt и cleanup до exact `ERASE`. USB-relative calibration использует отдельные малые HID reports ниже порога ускорения GPM и изолирует USB от PS/2; три повторных USB-прогона и полный matrix прошли перед freeze.
- Прежний direct-evdev/VMMouse twin selector удален. Stock `mousedev` aggregate и стандартный Newt console pointer прошли полный QEMU mouse matrix и ручную повторную проверку в VMware.
- GRUB сведен к трем пунктам без номера OpenWrt в названиях: unified installer с keyboard+mouse, загрузка установленного OpenWrt и keyboard-only failsafe installer.
- `Boot installed OpenWrt from local disk` становится default, когда GRUB находит раздел `kernel`; иначе default остается unified installer. UEFI ранний config закреплен за `(cd0)`, чтобы подключенный диск не обходил меню ISO.
- Unified installer проверяет official stable перед выбором диска: download предлагается только для строго более новой версии, а отсутствие сети и equal/older stable автоматически оставляют embedded image. Forced online CLI/kernel path сохранен для диагностики и QEMU acceptance.
- Online flow сначала автоматически пробует временный DHCP на Ethernet-интерфейсах, затем при необходимости предлагает ручные DHCP/static/PPPoE; pinned usign signature, exact SHA-256 entry, Content-Length/RAM reserve, gzip integrity и partition layout обязательны.
- Реальные QEMU online BIOS и UEFI download/install/installed-boot tests прошли 2026-08-14 с официальной stable версией OpenWrt `25.12.5`.
- После выбора target disk реализован импорт стандартного OpenWrt `sysupgrade -b` backup с FAT32/exFAT/NTFS3/ext4 USB: read-only mount, private RAM copy, строгая tar validation, config-only/full policy, imported/wizard network choice и повторный post-extract audit.
- USB backup никогда не распаковывается прямо в target rootfs; unsafe paths, links, special files, mode/size/member bombs и нехватка RAM отклоняются до destructive confirmation. Review и installed metadata содержат provenance и SHA-256, а stale installer-owned network metadata удаляется.
- Netinstall RAM-workspace больше не меняет process-wide `umask`, а config-import копирует только проверенное содержимое `etc/` и нормализует режим каталога. QEMU post-import boot подтверждает доступные `0755` режимы `/` и `/etc`, импортированные UCI и отсутствие stale installer state.
- `scripts/common.sh` фиксирует `umask 022`, чтобы ImageBuilder не создавал rootfs с `0700/0600` при запуске из hardened runner; добавлен `make build-env-smoke`.
- Для physical gate сохранен скрытый kernel flag `owrt.hardware-test=1`: его временно добавляют через GRUB edit к unified entry, он принудительно включает `--dry-run`, а `owrt-hardware-report` создает ограниченный отчет без сетевых и аппаратных серийных идентификаторов.
- Physical report schema v3 объединяет wired USB HID с обязательными
  storage/rescue checks для SATA, NVMe, restored boot и pre-ERASE power-cycle;
  schema v2 остается только историческим форматом.
- `make freeze-candidate VERSION=...` создает metadata только из clean non-dev commit и проверенных свежих artifacts; commit не выполняется автоматически. Manifest содержит `build_commit`/`build_dirty` и находится также в корне ISO.
- `make release-gate CANDIDATE=... REPORT=...` использует data-only parser, требует committed metadata, сверяет physical report, commit, ISO/sidecar/embedded manifest и отвергает tracked/staged/untracked/unexpected-ignored runtime. Изолированный Git smoke покрывает injection, dirty, checksum, hash и embedded-manifest rejection.
- GitHub Actions smoke gate опубликован в `main`: push/PR workflow запускает `make smoke` без разрешения на запись в repository. Первый run `31657834111` для commit `9e63814` успешно завершен за 43 секунды.
- Реальный GRUB-путь hardware-test проверен в QEMU; полный wizard до exact `ERASE` завершился в dry-run, GPM был остановлен перед подтверждением, а SHA-256 всего target disk до и после совпал.
- На замороженном `v1.0-alpha.9` candidate прошли `make smoke`, `make mouse-qemu-smoke`, BIOS/UEFI/VGA, local-disk BIOS/UEFI, missing-disk, hardware-test, install-to-disk/installed-system boot и config-import/install/boot через `make iso-smoke`.
- Реализованы `OWRT_UI_MODE=auto|line|ansi|whiptail|curses|dialog`, общий curses adapter и Hellforge frame/menu/review/confirm/install-stage screens.
- Network wizard теперь использует form-aware prompt screens для LAN IPv4, PPPoE и static WAN settings: на экране показываются context, example, current/default и error zone.
- `whiptail 0.52.24` добавлен как обязательный официальный package; local `TERM=linux` console использует его автоматически. `curses` выбирает работающий `dialog`, затем `whiptail`, затем ANSI.
- Пакет `dialog` в текущем OpenWrt `25.12.5` feed недоступен и остается optional; SSH/xterm auto mode использует ANSI для native SGR mouse.
- PPPoE теперь использует отдельные шаги username/password и для установленного WAN, и для временного online uplink. Back возвращает на предыдущее поле, значения сохраняются при редактировании, пароль скрыт и отсутствует в review. Для `whiptail --passwordbox` исправлена высота: пояснение подтверждено на реальной VMware-консоли через VNC `10.0.77.3:5900`.
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
- База сборки: официальный OpenWrt ImageBuilder `25.12.5` для `x86_64`, kernel `6.12.94`.
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
d405fde7740fb9e2d761c2687d53f74f76bf3484cc07ca91fc43731f65a62c9a  openwrt-x86-64-target.img.gz
5c1bb9e5e08d1b8f8e4e0a36a115236766c6282ed15ebd0aa352f3517b40ab6e  openwrt-x86-64-installer.img.gz
2b570a2e5747b0a9f2cd46c8252059dd64f101d35c0e14c06fdb69402cffd851  openwrt-x86-64-installer-hybrid.iso
2d957a424664e7d6a5f75b0646e226289446d13205c12db83e0a32db4c26bd15  manifest.json
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
- QEMU install smoke автоматически прошел disk/LAN/WAN/WAN6/review/erase flow, увидел `OWRT_INSTALLER_WRITE_PROGRESS=100`, загрузил записанный qcow2 и подтвердил `installer_version=v1.0-alpha.9`, `installed_by=openwrt-x86-installer`, `target_disk=/dev/vda`;
- deterministic `make config-import-smoke` проверил valid config-only/full restore, imported/wizard network, cleanup и hostile archive/resource-limit matrix без block-device privileges;
- финальный полный `make iso-smoke` job `27a90c6a290645c4ab277ed50a21fabe` прошел за 613 секунд на ISO `2b570a2e...`: BIOS/UEFI, local-disk BIOS/UEFI, missing-disk, hardware menu, VGA, clean install+boot и USB config-import+install+boot;
- checksum manifest прошел; `/manifest.json` в ISO и initramfs совпадает с sidecar byte-for-byte, provenance содержит commit `8e8593c5891ff69f98a9ee3ef5fcdd23444d2b51` и `build_dirty: false`. Build job: `7dc16e75ed8e4aff9730d1fb8739d2df`; fast smoke: `3ab67372c91348c29bdbaf01a54db3cf`; mouse QEMU: `7b4549590cc3470c81379e776716cc7e`; focused config-import: `acec1a31270a4e0ead0a82a5fbb9ccfe`;
- для frozen `v1.0-alpha.9` повторно пройдены BIOS/UEFI/VGA, hardware-test GRUB path и полный install smoke; установленная система подтвердила runtime marker, а local-mouse matrix отдельно проверила USB/PS2/absolute tablet/fallback/cleanup/disk immutability;
- online BIOS и UEFI QEMU acceptance скачали официальный OpenWrt `25.12.5`, проверили payload, установили соответствующие combined images и загрузили обе установленные системы с корректным `/etc/openwrt-installer-release`;
- финальный `make smoke local-disk-boot-smoke` прошел на OpenWrt `25.12.5`: syntax, ShellCheck, UI/PPPoE/online/install-flow и BIOS/UEFI local-disk boot; missing-disk menu path также прошел;
- VMware VNC-проверка 2026-08-14 визуально подтвердила исправленный скрытый PPPoE passwordbox. Frozen ISO `2b570a2e...` 2026-08-15 был повторно загружен на VM `10.0.77.3:5900`: визуально подтверждены ровно три GRUB entry, installer default при отсутствии локальной `kernel` label и autostart до выбора `/dev/sda`; установка и запись на диск не запускались. Conditional installed-disk default отдельно прошел BIOS/UEFI QEMU acceptance;
- `make smoke` и единый `make iso-smoke` прошли перед публикацией; checksum manifest, GPT, BIOS/UEFI El Torito entries, source/initramfs compare и embedded `pv 1.9.31` проверены;
- real pseudo-TTY smoke управляет настоящим host `whiptail`: Down/Enter, input edit, Esc/Back, password hiding, theme, shell-metacharacter safety и backend precedence/fallback;
- на serial видно, что live installer управляется `/etc/inittab` на `tty1`; serial остается fallback/login каналом.

## Как пользоваться

Записать ISO на USB через Rufus, balenaEtcher, Ventoy или `dd` и загрузиться с него. На локальной консоли `tty1` установщик стартует автоматически.

Если автозапуск не сработал или нужен ручной запуск, выполнить:

```sh
owrt-install
```
