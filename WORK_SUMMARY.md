# Краткий итог работ

Дата фиксации: 2026-06-03.

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
b95fcf8a4b133fe20cf80f65b9572019828580beec08341f2306a47686ef8e9f  openwrt-x86-64-installer.img.gz
a8ffa95bd1d7bec0a25a1cfbda0ae662236b43588da6a0f77d8243922a5343ce  openwrt-x86-64-installer-hybrid.iso
72852efd749c61b1ae85b4d0af977ce2d3952e22d7e43aca193226fbf85da9db  manifest.json
```

## Проверки

Выполнено:

- `make syntax-check`;
- `make shellcheck`;
- проверка `sha256sums.txt`;
- проверка ISO через `fdisk` и `xorriso`;
- проверка, что `owrt-install` внутри ISO совпадает с исходным файлом;
- smoke-тест логики выбора LAN/WAN на 2 и 3 интерфейсах;
- smoke-тест DHCP/static WAN wizard и CIDR-конвертации.
- локальная распаковка QEMU/OVMF в `build/qemu-local`;
- BIOS ISO boot smoke-test в QEMU: OpenWrt загрузился, `owrt-install --autostart` появился на консоли;
- UEFI ISO boot smoke-test в QEMU: OpenWrt загрузился, `owrt-install --autostart` появился на консоли.

## Как пользоваться

Записать ISO на USB через Rufus, balenaEtcher, Ventoy или `dd`, загрузиться и выполнить:

```sh
owrt-install
```
