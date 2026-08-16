# План Разметки Диска И Rescue Existing OpenWrt

Дата: 2026-08-15.

Статус: первая итерация sizing/rescue завершена. Вторая итерация storage
profiles, data partitions, fail-closed upgrade guard и Hellforge Safe Upgrade
вошла в `v1.0-beta.1` и прошла доступные fast/QEMU gates. Beta публикуется для
VM и осторожной hardware-оценки с явным предупреждением: physical SATA/NVMe
schema 4 gate еще не выполнен и bare-metal storage acceptance не заявляется.

Базовая версия storage-итерации: опубликованный prerelease `v1.0-alpha.10`.

## Утвержденная Вторая Итерация

Этот раздел заменяет ограничения первой итерации там, где они противоречат
новому storage contract.

### Профили

1. `OpenWrt-compatible (recommended)` сохраняет точную геометрию payload
   partitions 1 и 2, не использует `owut rootfs_size`, создает partition 3
   `ext4` на 80% оставшегося usable space и оставляет последние 20%
   неразмеченными.
2. `Expanded OpenWrt` сохраняет пресеты и custom размер partition 2 и может
   создавать data partitions, но показывает предупреждение о несовместимой
   геометрии обычного x86 `sysupgrade`.
3. `OpenWrt on entire disk` расширяет partition 2 до usable end и показывает
   такое же предупреждение.
4. `Custom partitioning` позволяет создать несколько data partitions с
   размером, ext4 label и mount point. Обычный `sysupgrade` для этого профиля
   не считается безопасным.

### Compatible Geometry

Все вычисления выполняются в 512-byte sectors с alignment 2048 sectors:

```text
p3_start = align_up(p2_end + 1, 2048)
remaining = usable_end - p3_start + 1
p3_size = align_down(floor(remaining * 80 / 100), 2048)
p3_end = p3_start + p3_size - 1
reserved = usable_end - p3_end
```

`usable_end` уже исключает backup GPT. Partition 3 получает GPT Linux
filesystem type или MBR type `0x83`, ext4 label `owrt-data` и mount point
`/mnt/data`. Target сохраняет profile, exact system geometry, filesystem UUID и
reserved sectors в UCI metadata; `/etc/config/fstab` использует filesystem UUID.

### Upgrade Contract

- Compatible profile допускает standard x86 partition-preserving upgrade
  только если candidate partitions 1/2 точно совпадают по number/start/size.
- Candidate не может содержать data partition 3+, иначе partition-wise
  `sysupgrade` перезапишет локальные данные. Разрешен только известный GPT
  auxiliary partition 128.
- Geometry mismatch, unsupported table или `sysupgrade -p` должны завершаться
  fail-closed до первой записи.
- Expanded/fill/custom profiles рекомендуют Hellforge Safe Upgrade либо
  system-only image с точно совпадающими partitions 1/2 и без data partition.
- Hellforge Safe Upgrade сохраняет partition table и data partitions, пишет
  payload только в existing partitions 1/2, проверяет и расширяет ext4,
  восстанавливает validated RAM configuration и заново проверяет boot/data
  geometry.

### SSD Reserve

Неразмеченный хвост называется `SSD reserve`, а не гарантированным
overprovisioning. После destructive confirmation installer может выполнить
full-device discard только для unmounted target с подтвержденной discard
support; при отсутствии или ошибке discard хвост остается unallocated с
пометкой `discard not verified`. Чтение нулей не используется как проверка
discard. Для data filesystem предпочтителен периодический `fstrim`.

### Реализация И Gates

1. Storage profile state, exact 80/20 arithmetic и multi-partition model.
2. Partition creation, ext4, target UCI metadata, UUID fstab и review UI.
3. Persistent fail-closed upgrade guard и проверка его восстановления после
   последовательного standard upgrade.
4. Hellforge Safe Upgrade без записи partition table или data partitions.
5. Unit/smoke tests, QEMU BIOS/UEFI и AHCI/NVMe matrix, затем physical SATA/NVMe
   install/upgrade gate.
6. README/work summary, clean hybrid ISO и новый immutable release candidate;
   frozen `v1.0-alpha.11` не изменяется.

## Короткий Вывод

Вторая итерация состоит из четырех связанных функций:

1. Recommended compatible profile сохраняет payload partitions 1/2, создает
   ext4 p3 на 80% остатка и оставляет 20% неразмеченным SSD reserve.
2. Expanded, fill и custom profiles дают управляемый root и несколько ext4
   data partitions с явным предупреждением о стандартном `sysupgrade`.
3. Установленная compatible-система получает persistent fail-closed wrapper,
   допускающий только локальный image с точно совпадающими partitions 1/2.
4. Для валидированной существующей Hellforge-разметки Safe Upgrade сохраняет
   partition table и data partitions, заменяет только p1/p2 и восстанавливает
   проверенную RAM-конфигурацию. Destructive rescue/reinstall остается
   отдельным вариантом.

RAID, изменение ядра, собственный MD/initramfs и модификация upstream
`sysupgrade`/`platform.sh` исключены из этого плана.

Стандартный `sysupgrade` по-прежнему не запускается из live ISO или через
`chroot`: он работает внутри реально загруженной установленной OpenWrt с ее
`procd`, `ubus`, kernel cmdline и boot device. Live ISO выполняет только
собственный Safe Upgrade с другим контрактом записи: validated p1/p2 write,
сохранение таблицы/data и последующая проверка.

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
- Не обещать сохранение custom partition geometry обычным combined image.
- Не разрешать `sysupgrade -p`, `sysupgrade -n`, remote URL или image с
  несовпадающими partitions 1/2 при наличии managed data partitions.

### Поддерживаемый Путь

Для compatible installation установленный persistent wrapper:

1. Проверяет текущие boot/root/data geometry, filesystem UUID/label и metadata.
2. Принимает только читаемый локальный image; URL отклоняется.
3. Проверяет table type, exact number/start/size partitions 1/2, отсутствие
   candidate data partitions и ext4 superblock candidate root.
4. Блокирует `-p` и `-n`, чтобы data и сам guard не могли быть потеряны.
5. Передает валидный image оригинальному `/sbin/sysupgrade.openwrt`.
6. Init service восстанавливает wrapper после первого boot.

Этот путь доказан двумя последовательными real `sysupgrade` циклами в одном
QEMU процессе с самостоятельным warm reboot. После каждого цикла проверяются
config, p3 data/mount/UUID, geometry, guard restore и kernel errors; полный GPT
dump до и после совпадает.

Action `Boot existing OpenWrt for standard upgrade` остается zero-write
handoff для любой распознанной existing installation. Expanded/fill/custom
без exact system-only image используют Safe Upgrade, если managed metadata
валидна, либо reinstall/rescue.

Live ISO Safe Upgrade не вызывает installed `sysupgrade`: после RAM snapshot и
exact `UPGRADE /dev/...` он сохраняет таблицу, пишет p1/p2 отдельно, расширяет
ext4 до существующей p2 boundary, исправляет GRUB PARTUUID, проверяет data до и
после restore и устанавливает новый persistent guard. До первой записи весь
распакованный payload создается как private file в RAM; проверяются exit status
gzip, exact manifest size и наличие `payload size + 128 MiB` свободной памяти.
Только обычный файл используется как источник byte-exact p1/p2 ranges, поэтому
короткие чтения pipe не могут сместить sector offset. Ошибка staging завершает
операцию до изменения p1.

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
- [x] Разрешить отдельную VM/QEMU evaluation beta с явным physical-gate
  disclaimer.
- [ ] Пройти physical SATA/NVMe rescue gate.
- [ ] Опубликовать hardware-validated prerelease только после checksums и
  schema 4 report.

### Фаза 5: Storage Profiles И Safe Upgrade

- [x] Добавить compatible/expanded/fill/custom profile state и review UI.
- [x] Реализовать exact compatible p1/p2, ext4 p3 80% и SSD reserve 20%.
- [x] Реализовать несколько custom ext4 data partitions с label/mount point.
- [x] Сохранять UCI metadata, UUID fstab и mode `0600` layout snapshot.
- [x] Добавить full-device discard attempt и target `fstrim` package.
- [x] Добавить persistent fail-closed standard sysupgrade guard.
- [x] Реализовать Hellforge Safe Upgrade с RAM restore и сохранением data.
- [x] Пройти fast smoke, UEFI profile matrix, Safe Upgrade, rescue/import и два
  последовательных standard sysupgrade цикла.
- [x] Пройти QEMU AHCI/NVMe compatible matrix и pre-ERASE immutability.
- [x] Поднять physical report и release verifier до schema 4.
- [x] Подготовить `v1.0-beta.1` runtime и VMware screenshots для evaluation
  prerelease.
- [ ] Собрать и проверить финальный clean `v1.0-beta.1` artifact.
- [ ] Пройти physical SATA/NVMe compatible, standard/Safe Upgrade и rescue
  schema 4 gate.
- [ ] Опубликовать новый immutable prerelease после physical report.

## Автоматизированное Подтверждение

Frozen candidate `v1.0-alpha.11` остается неизменным историческим артефактом
первой sizing/rescue итерации. Runtime, выпущенный как `v1.0-beta.1`, на
2026-08-16 прошел:

- полный `make smoke`, включая ShellCheck, profile/geometry/rescue fixtures,
  fail-closed guard cases, schema 4 hardware report и isolated release gate;
- byte-exact Safe Upgrade staging regression с намеренным коротким первым
  чтением gzip producer, exact file comparison и low-RAM отказом до записи;
- UEFI `fill`, `image`, preset `4 GiB` и custom `5120 MiB` install/reboot с
  несколькими data partitions, exact sectors, ext4, UUID fstab, PARTUUID,
  unallocated tail и backup GPT в конце target disk;
- compatible install/reboot с p3 `/mnt/data`, exact 80/20 calculation,
  metadata и persistent guard;
- два последовательных реальных standard `sysupgrade` цикла с warm reboot,
  partition-wise p1/p2 writes, config/data preservation, guard restore,
  отсутствием panic/oops и exact GPT comparison;
- Safe Upgrade с исходной config/data evidence, неизменной p1/p2/p3 geometry,
  восстановленной конфигурацией и повторной проверкой data после boot;
- full `/etc` rescue существующей OpenWrt с удалением stale installer state,
  сохранением UCI и directory modes, package inventory и installed reboot;
- zero-write standard-upgrade handoff через byte comparison qcow2;
- official OpenWrt `25.12.5` online BIOS/MBR bounded и UEFI/GPT fill
  download/install/reboot;
- pre-ERASE payload ext4-superblock invariant для embedded и официальных
  downloaded combined images; любой посторонний payload partition отклоняется,
  при этом поддерживается стандартный малый GPT auxiliary partition 128.
- device matrix: QEMU AHCI `/dev/sda` и NVMe `/dev/nvme0n1`, compatible p3,
  UUID fstab, exact 80/20 reserve, guard после boot, неизменный дополнительный
  диск и `qemu-img compare` source после RAM rescue snapshot с выключением на
  exact `ERASE` prompt.

Меняющиеся checksums локального artifact и longrun job IDs записываются в
ignored `LOCAL_CONTEXT.md`. Evaluation beta не означает прохождение physical
schema 4 gate.

TCG-диагностика отдельно установила, что QEMU 8.2 с двумя vCPU может замедлять
guest clock после warm reset независимо от `sysupgrade`; тот же простой reboot
с одним vCPU проходит. Поэтому standard-upgrade gate сохраняет настоящий warm
reboot, но использует отдельный `QEMU_STANDARD_UPGRADE_SMP=1` профиль.

Эти результаты не закрывают physical gate. Реальные SATA и NVMe, два
standard upgrade цикла, Safe Upgrade, физический power-cycle до `ERASE`, schema
4 report и prerelease остаются неотмеченными пунктами Фазы 5.

### Отложенная Фаза: Export И Assisted Upgrade

- [ ] Export RAM rescue snapshot на выбранный USB до ERASE.
- [ ] Исследовать read-only detection squashfs + overlay.

## Definition Of Done

Storage profiles готовы, когда BIOS/UEFI и AHCI/NVMe установки compatible,
expanded, fill и custom проходят installed boot, а фактические sectors,
filesystems, UUID fstab, data mounts, reserve и review совпадают. Эти
автоматические gates пройдены.

Rescue готов, когда старая ext4 OpenWrt читается строго read-only, snapshot
полностью находится и повторно проверяется в RAM до ERASE, source unmounted до
write, новая система загружается и содержит ожидаемую конфигурацию.

Standard upgrade готов автоматически, когда wrapper fail-closed проверяет
installed/candidate geometry, два последовательных original OpenWrt
`sysupgrade` проходят самостоятельный reboot, data/config сохраняются, а guard
восстанавливается. Этот QEMU gate пройден; physical gate еще открыт.

Safe Upgrade готов автоматически, когда RAM snapshot, p1/p2-only write,
root resize/PARTUUID patch, data verification и installed boot доказаны. Этот
QEMU gate пройден; physical gate еще открыт.

Полная storage release iteration готова только после clean non-dev build,
schema 4 bare-metal SATA/NVMe/standard/Safe Upgrade/rescue report и immutable
release gate. `v1.0-beta.1` до этого остается evaluation beta, а physical
storage Goal не считается полностью закрытым.

## Ссылки

- OpenWrt x86 partition layout и предупреждение о combined images:
  <https://openwrt.org/docs/guide-user/installation/openwrt_x86>
- OpenWrt sysupgrade technical reference:
  <https://openwrt.org/docs/techref/sysupgrade>
- OpenWrt backup and restore:
  <https://openwrt.org/docs/guide-user/troubleshooting/backup_restore>
- OpenWrt `owut` и `--rootfs-size`:
  <https://openwrt.org/docs/guide-user/installation/sysupgrade.owut>
