# План CUSTOM_BUILD И OpenWrt Logo

Дата: 2026-08-22.

База: опубликованный `v1.0-beta.1`. Новая работа идет как следующая
development-итерация и не изменяет существующий tag или release assets.

Статус: реализовано в runtime commit `ff4fbdbe94bcb3ac8f95c334f1fc5bdd041323ef`;
mouse-test calibration завершена в `db1bd08`. Clean development ISO собран и
прошел fast smoke, полный QEMU ISO gate, отдельные BIOS/UEFI CUSTOM_BUILD
install/boot, полную mouse matrix и VMware `90x25` visual acceptance. Новый
GitHub release не публиковался.

## Цель

1. Добавить классический OpenWrt ASCII banner над Hellforge dialog UI без
   потери keyboard/mouse управления и без перекрытия окон на `80x24`.
2. Добавить в installer media каталог `/CUSTOM_BUILD` и безопасный выбор
   пользовательского OpenWrt x86 image до выбора target disk.

## CUSTOM_BUILD Contract

- Поддерживаются только regular non-symlink `CUSTOM_BUILD/*.img.gz` напрямую
  в корне каталога, максимум 64 entries.
- Принимается только `x86/64 generic ext4 combined` layout, реально
  подтвержденный существующим MBR/GPT/ext4 inspector. Имя файла не является
  доказательством формата.
- Boot mode должен совпадать с текущим запуском installer: BIOS принимает MBR
  combined, UEFI принимает GPT combined-efi. Неоднозначный layout отклоняется.
- Источники: текущая `/CUSTOM_BUILD`, optical `iso9660` и корневая
  `/CUSTOM_BUILD` на USB/removable FAT32, exFAT, NTFS3 или ext4 partition.
- Внешний filesystem всегда монтируется
  `ro,nosuid,nodev,noexec`; ext4 дополнительно использует `noload`.
- До копирования проверяются regular-file type, отсутствие symlink, размер и
  `MemAvailable`. Copy строго ограничен проверенным размером плюс максимум один
  служебный byte; повторный `stat` обязан совпасть.
- Image и найденный checksum sidecar копируются в private mode `0700` RAM
  workspace до unmount source. После unmount проверяются exact copied size,
  SHA-256 и optional sidecar.
- Sidecar может быть `<image>.sha256` или root `sha256sums`; неоднозначный,
  malformed или несовпадающий checksum отклоняет image. Отсутствие sidecar
  допускается только после явного unsigned custom warning.
- `gzip -t` обязателен. True uncompressed size считается bounded streaming
  decompression, а не берется из spoofable gzip ISIZE footer. Верхний предел:
  `4 GiB`; compressed image: `1 GiB`.
- Internal manifest всегда помечает source как `custom-build`, version как
  `custom-<filename-version>` или `custom-unsigned`, а URL как локальный
  source label. Custom image никогда не называется официально подписанным.
- После validation используется существующий target/review/ERASE/write flow.
  Review всегда показывает custom source, SHA-256 и unsigned/checksum status.
- Если custom images не найдены, текущий automatic latest/embedded flow не
  получает дополнительного экрана.

## Media Layout

- `files-installer/CUSTOM_BUILD/README.txt` создает каталог в raw installer
  image.
- Hybrid builder копирует этот каталог в ISO root.
- Custom images из source tree исключаются из hybrid initramfs и остаются один
  раз в ISO root, чтобы не удваивать размер ISO.
- Для готового read-only ISO доступны Ventoy/отдельный USB partition либо
  remastering. Raw ext4 installer image можно заполнить с Linux до boot.

## Logo Contract

- Canonical OpenWrt ASCII banner используется как multiline backtitle.
- Local patched `whiptail` преобразует escaped newlines, рисует несколько root
  rows и резервирует их при расчете/позиционировании window.
- ANSI backend рисует тот же banner перед рамкой.
- `line`, serial и narrow fallback остаются без fullscreen logo.
- На `80x24` banner не должен перекрывать menu/input/password/review windows;
  слишком высокие окна получают bounded viewport/scroll behavior.
- GPM mouse pointer, click targets и keyboard controls не меняются.

## Этапы

1. [x] Добавить plan и bump development version.
2. [x] Реализовать/протестировать multiline `whiptail` backtitle и ANSI banner.
3. [x] Реализовать custom-build library, source selection и CLI parity
   `--custom-build FILE`.
4. [x] Добавить media folder, build wiring, cleanup и checksum provenance.
5. [x] Добавить deterministic fast tests: discovery, bounded copy, sidecar,
   gzip/size/layout/boot mode, unsigned confirmation, source cleanup и UI.
6. [x] Пройти syntax, ShellCheck и полный `make smoke`.
7. [x] Собрать новые mouse packages и clean hybrid ISO.
8. [x] Пройти BIOS/UEFI custom-image QEMU install/boot, mouse QEMU и VMware VNC
   visual acceptance без записи физического disk.

## Не Входит В Эту Итерацию

- Squashfs images, non-x86 targets, raw uncompressed `.img`, arbitrary nested
  directories, package feeds и доверие к произвольному custom manifest.
- Запись файлов внутрь уже опубликованного read-only ISO без remastering.
- Публикация нового GitHub release до отдельного запроса и release gate.
