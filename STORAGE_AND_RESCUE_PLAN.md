# План Разметки Диска И Rescue Existing OpenWrt

Дата: 2026-08-15.

Статус: реализация и автоматизированная приемка завершены; physical SATA/NVMe
gate и публикация prerelease еще не выполнены.

Базовая версия проекта: опубликованный prerelease `v1.0-alpha.10`.

## Короткий Вывод

Следующая итерация состоит из двух связанных функций:

1. После выбора одного целевого диска пользователь выбирает размер раздела
   OpenWrt: исходный размер образа, весь доступный диск, готовый пресет или
   собственный размер. Неиспользованный хвост остается неразмеченным.
2. Если на выбранном диске найдена существующая ext4-установка OpenWrt,
   installer предлагает `Rescue and upgrade`: безопасно копирует конфигурацию
   в RAM, отключает старый раздел, устанавливает выбранный проверенный образ и
   восстанавливает конфигурацию через уже существующий строгий import path.

RAID, изменение ядра, собственный MD/initramfs и модификация upstream
`sysupgrade`/`platform.sh` исключены из этого плана.

Стандартный `sysupgrade` нельзя безопасно запускать из live ISO или через
`chroot`: он должен работать внутри реально загруженной установленной OpenWrt с
ее `procd`, `ubus`, kernel cmdline и boot device. Поэтому wizard только
предлагает загрузить существующую систему для штатного обновления через LuCI,
`sysupgrade` или `owut`. Автоматический one-shot upgrade из ISO не входит в
MVP.

## Исходное Поведение До Реализации

- Embedded target являлся официальным x86/64 `ext4-combined-efi` образом.
- В текущем payload раздел 1 занимает 16 MiB, раздел 2 содержит ext4 rootfs
  размером 256 MiB.
- До этой итерации после записи `owrt-install` всегда выполнял
  `parted -s -f "$target" resizepart 2 100%`, затем `e2fsck` и `resize2fs`.
- Поэтому прежняя установка занимала разделом 2 весь оставшийся диск.
- GRUB ISO уже обнаруживает раздел с label `kernel` и делает пункт загрузки
  установленной OpenWrt вариантом по умолчанию.
- Import OpenWrt backup уже умеет безопасно копировать archive в private RAM,
  проверять tar, ограничивать размер и число файлов, выбирать `config-only` или
  `full` и применять только проверенное дерево `etc/`.
- Официальный x86 `sysupgrade` использует platform-specific код текущей
  загруженной системы. Его нельзя корректно направить на выбранный диск live
  installer простым `chroot`.

## Границы Решения

В первой реализации поддерживается:

- один целевой SSD, SATA, NVMe или виртуальный диск;
- ext4 target image;
- MBR `ext4-combined` и GPT `ext4-combined-efi` layout;
- выбор размера только раздела OpenWrt rootfs;
- неразмеченное пространство после OpenWrt;
- автоматический rescue существующего OpenWrt ext4 rootfs;
- config-only и full `/etc` rescue policy;
- переход к загрузке существующей OpenWrt для штатного обновления.

Не поддерживается в этой итерации:

- RAID любого уровня;
- автоматическое создание data partition;
- сохранение уже существующих дополнительных разделов при переустановке;
- LVM, LUKS, ZFS, Btrfs или dual boot;
- автоматический rescue squashfs/overlay установки;
- запуск установленного `sysupgrade` из live ISO или через `chroot`;
- изменение upstream OpenWrt kernel, `sysupgrade` или `platform.sh`.

Это важный контракт: выбранный для переустановки диск по-прежнему полностью
считается destructive target. Неразмеченный хвост создается для последующего
ручного использования, но первая версия installer не обещает сохранить
созданные там позднее разделы при следующей переустановке.

## Новый Wizard Flow

### Диск Без Обнаруженной OpenWrt

```text
Select target disk
  -> Inspect selected payload and disk geometry
  -> Select installation type
       Clean installation
       Import OpenWrt backup from USB
       Back
  -> Select OpenWrt partition size
  -> Import or LAN/WAN wizard
  -> Review layout and configuration
  -> Exact ERASE confirmation
  -> Install
```

### Диск С Обнаруженной OpenWrt ext4

```text
Select target disk
  -> Read-only existing-system probe
  -> Existing OpenWrt detected: version, revision, root partition
  -> Select action
       Rescue and upgrade (recommended)
       Boot existing OpenWrt for standard upgrade
       Clean installation
       Import backup from USB
       Back
```

Для `Rescue and upgrade`:

```text
Select rescue scope
  -> Copy bounded snapshot to private RAM
  -> Unmount old root
  -> Validate RAM snapshot with existing importer
  -> Select OpenWrt partition size
  -> Keep rescued network or run LAN/WAN wizard
  -> Review source version, target version, layout and snapshot hash
  -> Exact ERASE confirmation
  -> Reinstall and restore
```

Для `Boot existing OpenWrt for standard upgrade` installer ничего не пишет на
диск. Он показывает, что штатный upgrade должен выполняться из загруженной
OpenWrt, и предлагает reboot. При подключенном ISO существующий GRUB path уже
является default, если найден label `kernel`.

## Wizard Размера OpenWrt

### Пункты Меню

Порядок вариантов:

1. `Use entire disk` - текущее поведение и default для обратной совместимости.
2. `4 GiB OpenWrt, leave the rest unallocated` - понятный безопасный пресет.
3. `8 GiB OpenWrt, leave the rest unallocated`.
4. `16 GiB OpenWrt, leave the rest unallocated`.
5. `32 GiB OpenWrt, leave the rest unallocated`.
6. `Keep original image size` - advanced, обычно 256 MiB.
7. `Custom size` - целое число MiB или GiB.
8. `Back`.

Показываются только пресеты, которые помещаются на выбранном диске. Custom
input принимает строгий формат `NNNM`, `NNNG`, `NNN MiB` или `NNN GiB`, после
чего сразу нормализуется в целое число MiB. Проценты в первой версии не нужны:
они менее предсказуемы и затрудняют точную проверку границ.

### Preview

Перед подтверждением wizard показывает стабильный текстовый preview:

```text
Disk:       /dev/nvme0n1, 238.5 GiB
Boot:       existing image partition, 16 MiB
OpenWrt:    partition 2, 8 GiB ext4
Unallocated: approximately 230.5 GiB
Update path: Rescue and upgrade; standard image upgrades may reset geometry
```

Whiptail/ANSI/line backends используют одни и те же значения. В TUI это menu,
inputbox и review, а не псевдографический редактор с перетаскиванием границ.
Так сохраняются keyboard, mouse и serial fallback без отдельной partition GUI.

### Минимум И Максимум

- Installer никогда не уменьшает filesystem из payload.
- Минимальный технический размер равен фактическому размеру partition 2 в
  выбранном payload, округленному вверх до MiB.
- Значения меньше 1 GiB доступны только через `Keep original image size` или
  custom input с отдельным warning.
- Размер выравнивается по 1 MiB.
- Для GPT резервируется место под backup partition table.
- Для MBR последний сектор не выходит за physical disk.
- Все вычисления выполняются в integer sectors/bytes, не по округленной строке
  из `disk_size()`.

## Модель Состояния

Новые переменные installer:

```text
STORAGE_LAYOUT=fill|bounded|image
ROOTFS_TARGET_MIB=<integer>
ROOTFS_START_SECTOR=<integer>
ROOTFS_IMAGE_SECTORS=<integer>
ROOTFS_TARGET_END_SECTOR=<integer>
TARGET_DISK_SECTORS=<integer>
TARGET_LOGICAL_SECTOR_SIZE=<integer>
UNALLOCATED_MIB=<integer>

EXISTING_OPENWRT=0|1
EXISTING_ROOT_PART=<device>
EXISTING_BOOT_PART=<device>
EXISTING_VERSION=<string>
EXISTING_REVISION=<string>
EXISTING_TARGET=<string>
EXISTING_FSTYPE=ext4
EXISTING_PROBE_REASON=<string>

INSTALL_MODE=clean|import|rescue
RESCUE_SCOPE=config-only|full
RESCUE_SOURCE_VERSION=<string>
RESCUE_SNAPSHOT_SHA256=<hex>
```

CLI parity добавляется после интерактивного flow:

```text
--root-size fill|image|<MiB|GiB>
--rescue-existing
--rescue-scope config-only|full
```

`--target` без `--root-size` сохраняет текущее `fill` поведение. Rescue в
non-interactive режиме требует оба explicit flags и существующий валидный
OpenWrt root; silent fallback на clean install запрещен.

## Payload Layout Inspector

Текущий `validate_downloaded_layout()` уже создает sparse probe и проверяет
partition table. Его следует вынести в общий `inspect_payload_layout()` для
embedded и downloaded payload.

Inspector обязан определить:

- uncompressed image size;
- MBR или GPT;
- logical sector size, ожидаемый образом;
- partition 1 start/end;
- partition 2 start/end и размер;
- отсутствие overlap;
- последний допустимый сектор target disk;
- поддерживаемый layout `root partition = 2`.

Для машинно-читаемого вывода использовать `parted -m -s ... unit s print` или
строго ограниченный parser текущего `fdisk -l` report. Не разбирать
локализованные human-readable размеры.

Unknown layout блокируется до выбора destructive action. Installer не должен
угадывать номер root partition по одному имени файла.

## Реализация Размера Раздела

Текущая `resize_rootfs(target, rootpart)` заменяется на функцию с вычисленным
концом:

```text
resize_rootfs(target, rootpart, target_end_sector)
```

Последовательность:

1. До ERASE проверить payload layout и capacity target disk.
2. Записать payload существующим verified stream path.
3. Перечитать partition table.
4. Для `image` оставить partition 2 без изменения.
5. Для `fill` вычислить последний usable sector.
6. Для `bounded` вычислить
   `end = start + root_size_sectors - 1`.
7. Выполнить `parted -s -f "$target" unit s resizepart 2 "${end}s"`.
8. Перечитать table и проверить фактические start/end sectors.
9. Проверить `TYPE=ext4` через `blkid`.
10. Выполнить `e2fsck -f -y`, `resize2fs`, повторный `e2fsck` и `sync`.
11. Проверить filesystem block count и итоговый размер partition.

Если table или filesystem после resize не совпали с расчетом, установка
завершается failure screen и не переходит к записи конфигурации.

## Existing OpenWrt Probe

Probe запускается только после выбора whole disk и до любого write.

### Правила Обнаружения

1. Перечислить только partitions выбранного диска.
2. Найти boot partition с filesystem label `kernel`.
3. Сначала проверить partition 2, затем другие ext4 partitions как fallback.
4. Монтировать candidate только с
   `ro,noload,nosuid,nodev,noexec` в private mount directory.
5. Не выполнять и не source-ить ни один файл с target disk.
6. Прочитать значения из `/etc/openwrt_release` ограниченным parser:
   `DISTRIB_ID`, `DISTRIB_RELEASE`, `DISTRIB_REVISION`, `DISTRIB_TARGET`.
7. Принять только `DISTRIB_ID=OpenWrt` и x86 target.
8. Проверить наличие `/etc/config` и обычных regular files.
9. Всегда unmount перед показом action menu.

Если ext4 dirty и `ro,noload` не позволяет получить конфигурацию, rescue не
предлагается как готовый action. UI показывает причину и оставляет clean,
USB-import и boot-existing варианты. Автоматический `e2fsck -y` старого диска
до RAM snapshot запрещен.

Squashfs/overlay installation может быть распознана для informational screen,
но automatic rescue блокируется до отдельной реализации merged overlay mount.

## Rescue Snapshot В RAM

### Политики

`Configuration only (recommended)`:

- копирует только regular files и directories из `/etc/config`;
- лучше переносится между версиями;
- после restore предлагает LAN/WAN wizard или сохранение rescued network.

`Full /etc rescue (advanced)`:

- копирует regular files и directories из `/etc`;
- может вернуть root password, SSH keys, custom scripts и package settings;
- исключает symlinks, sockets, devices и FIFOs; regular hardlinks копируются
  как независимые regular files без сохранения link relationship;
- исключает stale installer-owned state:
  `/etc/owrt-installer`, `/etc/openwrt-installer-release` и
  `/etc/uci-defaults/98-installer-network`;
- требует отдельный warning о cross-version incompatibility.

Пакеты автоматически не переустанавливаются. Если доступна package database,
rescue сохраняет sanitized package inventory как metadata и показывает это в
review, но не добавляет пакеты в новый image без отдельного решения.

### RAM И Filesystem Safety

До копирования вычисляются:

- число regular files;
- сумма `st_size`;
- максимальный размер одного файла;
- доступная RAM;
- reserve для live installer, downloaded payload и extraction staging.

Defaults используют существующие ограничения importer: 64 MiB compressed,
128 MiB unpacked, 32 MiB single member, 8192 members и отдельный RAM reserve.
До чтения source tree rescue требует консервативный peak budget 576 MiB
свободной RAM: source stage/archive, повторная import copy/extraction,
filtered apply tree и reserve должны одновременно помещаться до ERASE.

Collector создает private directory с `umask 077`, переносит только проверенные
regular files, формирует `etc/...` archive, считает SHA-256 и пропускает archive
через существующий `config_import_validate_ram_archive()`. Source partition
unmount-ится сразу после bounded copy и до создания/проверки archive; snapshot
получает state `ready` только после успешной повторной validation.

Перед ERASE review явно сообщает:

```text
The old configuration is currently stored only in RAM.
A power loss after disk erase can destroy both the old installation and this copy.
```

Отдельным последующим улучшением можно добавить `Export rescue snapshot to USB`
до erase. Оно не блокирует RAM-only MVP, но рекомендуется для physical release.

## Restore И Network Policy

Rescue переиспользует текущий `config_import_apply_to_target()` вместо второго
restore engine.

После snapshot пользователь выбирает:

- `Keep rescued network configuration`;
- `Configure LAN/WAN for this machine`.

Если `/etc/config/network` отсутствует, автоматически запускается LAN/WAN
wizard. Если selected payload старее source OpenWrt, rescue блокируется по
умолчанию и предлагает clean install либо явный advanced downgrade warning.

Installed metadata дополняется:

```text
install_mode=rescue
rescue_source_disk=/dev/...
rescue_source_version=...
rescue_source_revision=...
rescue_scope=config-only|full
rescue_snapshot_sha256=...
storage_layout=fill|bounded|image
rootfs_target_mib=...
unallocated_mib=...
```

## Стандартный Sysupgrade

### Что Не Делать

- Не запускать live ISO `/sbin/sysupgrade` для выбранного target disk.
- Не запускать installed `/sbin/sysupgrade` через `chroot`.
- Не подменять `/lib/upgrade/platform.sh`.
- Не инжектировать unattended one-shot init service в MVP.
- Не обещать сохранение custom partition geometry обычным combined image.

### Поддерживаемый Путь

Если existing OpenWrt выглядит загрузочной, action
`Boot existing OpenWrt for standard upgrade`:

1. Ничего не монтирует read-write и ничего не изменяет.
2. Показывает detected version и доступную selected payload version.
3. Предупреждает, что обычный x86 combined image может вернуть partition 2 к
   размеру образа и уничтожить entries дополнительных partitions.
4. Для custom root size предлагает проверить `owut --rootfs-size` в
   установленной системе, если `owut` доступен.
5. Предлагает reboot; local OpenWrt GRUB entry уже становится default.

Прямой assisted handoff можно повторно рассмотреть только после отдельного
QEMU proof. Минимальные gates для такого будущего эксперимента:

- installed system успешно загружается;
- его собственный `/sbin/sysupgrade -T` принимает exact image;
- image type совпадает с MBR/GPT layout;
- target version не является downgrade;
- достаточно persistent space и RAM;
- нет дополнительных target partitions, которые sysupgrade может уничтожить;
- failure не создает reboot loop;
- стандартный `sysupgrade`, а не код installer, выполняет flash.

До прохождения всех gates wizard не показывает автоматический sysupgrade как
доступную команду.

## Review И Destructive Confirmation

Review для переустановки обязан включать:

- exact target disk, model и serial;
- source и target OpenWrt versions;
- clean/import/rescue mode;
- payload filename, source, boot mode и SHA-256;
- current root size, requested root size и unallocated remainder;
- rescue scope, file count, compressed/unpacked size и snapshot SHA-256;
- network source;
- предупреждение о полном erase выбранного диска;
- предупреждение о RAM-only rescue copy.

Из review добавляются безопасные edit actions:

- edit storage size;
- edit rescue/import scope;
- edit network;
- cancel.

Exact phrase остается keyboard-only:

```text
ERASE /dev/...
```

Ни mouse click, ни `--yes` в interactive path не заменяют exact phrase.

## Тестовый План

### Fast Smoke

- parser `fill`, `image`, MiB и GiB;
- zero, negative, overflow, malformed units и whitespace rejection;
- 1 MiB alignment;
- GPT и MBR last usable sector;
- payload root larger than requested;
- requested root larger than disk;
- presets filtered by capacity;
- Back сохраняет выбранный disk/action и не пишет диск;
- CLI требует explicit rescue flags;
- unknown payload layout rejected before ERASE.

### Rescue Smoke Без QEMU

- valid ext4-like fixture detection;
- forged `openwrt_release` rejected;
- no shell sourcing from target;
- `ro,noload,nosuid,nodev,noexec` mount arguments;
- config-only snapshot;
- full snapshot;
- symlink, FIFO, device and newline path rejection/skipping, plus safe regular
  copies of hardlinked files;
- member count, single-file, total-size and low-RAM gates;
- stale installer metadata removal;
- source unmounted before `write_payload`;
- cleanup on Cancel, INT, TERM, validation failure and mount failure.

### QEMU Storage Matrix

- GPT/UEFI target: image, 4 GiB, custom and fill;
- MBR/BIOS online target: image, 4 GiB, custom and fill;
- disks smaller and larger than presets;
- verify partition start/end sectors after install;
- verify ext4 size with `dumpe2fs`/`resize2fs` data;
- verify expected unallocated tail;
- boot installed system after every layout;
- confirm no write before exact ERASE;
- compare checksum of an unrelated third disk before/after.

### QEMU Rescue Matrix

- install alpha baseline, change UCI config, reboot installer, detect and rescue;
- same-version reinstall;
- upgrade older source to newer payload;
- config-only and full `/etc` restore;
- keep rescued network and replace through wizard;
- downloaded and embedded payload;
- dirty ext4 mounted only with `ro,noload` or rejected;
- insufficient RAM before erase;
- corrupted ext4 and missing `/etc/config`;
- squashfs detected but rescue disabled with clear reason;
- restored system boots and exposes expected UCI values;
- stale installer metadata does not survive;
- package inventory is informational only.

### Standard Upgrade Handoff

- action performs zero target writes;
- reboot with ISO attached selects local disk by default;
- missing `kernel` label returns a clear error;
- custom-size warning is visible;
- no `sysupgrade` process starts in live ISO.

### Physical Gate

- SATA SSD and NVMe target;
- mouse and keyboard navigation through storage/rescue screens;
- rescue actual OpenWrt ext4 installation with changed LAN/WAN config;
- power-cycle after successful snapshot but before ERASE changes nothing;
- installed system boots with requested root size;
- rescue-upgraded system restores configuration and remains reachable.

## Этапы Реализации

### Фаза 0: Общий Geometry Layer

- [x] Вынести shared payload layout inspector.
- [x] Добавить exact disk byte/sector helpers.
- [x] Добавить storage state и CLI parser.
- [x] Покрыть MBR/GPT geometry smoke tests.

### Фаза 1: Partition Size Wizard

- [x] Добавить storage menu после installation action.
- [x] Добавить presets, custom input и preview.
- [x] Заменить unconditional `100%` на calculated end sector.
- [x] Добавить post-resize partition/filesystem verification.
- [x] Расширить review, logs и installed metadata.
- [x] Пройти full smoke и QEMU BIOS/UEFI matrix.

### Фаза 2: Existing OpenWrt Detection

- [x] Добавить selected-disk partition probe.
- [x] Реализовать safe parser `/etc/openwrt_release`.
- [x] Добавить strict read-only ext4 mount helper.
- [x] Добавить existing-system action screen.
- [x] Добавить boot-existing handoff без target writes.

### Фаза 3: RAM Rescue

- [x] Добавить bounded regular-file collector.
- [x] Переиспользовать import validator и apply path.
- [x] Добавить rescue scope и network policy.
- [x] Добавить source/target version gate.
- [x] Добавить RAM-only warning и metadata.
- [x] Пройти rescue smoke и QEMU install-rescue-boot matrix.

### Фаза 4: Release Gate

- [x] Обновить README и CLI help.
- [x] Обновить hardware report schema для storage/rescue result.
- [x] Собрать clean hybrid ISO.
- [ ] Пройти physical SATA/NVMe rescue gate.
- [ ] Опубликовать отдельный prerelease только после checksums и report.

## Автоматизированное Подтверждение

На frozen candidate `v1.0-alpha.11` пройдены:

- полный `make smoke`, включая ShellCheck, geometry/rescue fixtures, version
  relation, EXIT cleanup, schema 3 hardware report и isolated release gate;
- UEFI `fill`, `image`, preset `4 GiB` и custom `5120 MiB` install/reboot с
  проверкой exact sectors, ext4, PARTUUID, unallocated tail и backup GPT в
  конце target disk;
- full `/etc` rescue существующей OpenWrt с удалением stale installer state,
  сохранением UCI и directory modes, package inventory и installed reboot;
- zero-write standard-upgrade handoff через byte comparison qcow2;
- official OpenWrt `25.12.5` online BIOS/MBR bounded и UEFI/GPT fill
  download/install/reboot;
- pre-ERASE payload ext4-superblock invariant для embedded и официальных
  downloaded combined images; любой посторонний payload partition отклоняется,
  при этом поддерживается стандартный малый GPT auxiliary partition 128.
- отдельный frozen-ISO device matrix: QEMU AHCI `/dev/sda` и NVMe
  `/dev/nvme0n1`, exact target metadata после reboot, неизменный дополнительный
  диск и `qemu-img compare` source после RAM rescue snapshot с выключением на
  exact `ERASE` prompt.

Эти результаты не закрывают physical gate. Реальные SATA и NVMe, физический
power-cycle до `ERASE`, schema 3 report и prerelease остаются отдельными
неотмеченными пунктами Фазы 4.

### Отложенная Фаза: Export И Assisted Upgrade

- [ ] Export RAM rescue snapshot на выбранный USB до ERASE.
- [ ] Исследовать read-only detection squashfs + overlay.
- [ ] Проверить `owut --rootfs-size` на project-created layouts.
- [ ] Решить, нужен ли вообще one-shot standard sysupgrade handoff.

## Definition Of Done

Partition sizing готов, когда BIOS и UEFI установки с `image`, fixed/custom и
`fill` размерами проходят QEMU boot, а фактическая partition/filesystem geometry
совпадает с review.

Rescue готов, когда старая ext4 OpenWrt читается строго read-only, snapshot
полностью находится и повторно проверяется в RAM до ERASE, source unmounted до
write, новая система загружается и содержит ожидаемую конфигурацию.

Стандартный upgrade считается поддержанным только как zero-write переход к
существующей OpenWrt. Автоматический upgrade из live ISO не считается частью
готовности и не должен появляться в UI без отдельного доказанного design.

## Ссылки

- OpenWrt x86 partition layout и предупреждение о combined images:
  <https://openwrt.org/docs/guide-user/installation/openwrt_x86>
- OpenWrt sysupgrade technical reference:
  <https://openwrt.org/docs/techref/sysupgrade>
- OpenWrt backup and restore:
  <https://openwrt.org/docs/guide-user/troubleshooting/backup_restore>
- OpenWrt `owut` и `--rootfs-size`:
  <https://openwrt.org/docs/guide-user/installation/sysupgrade.owut>
