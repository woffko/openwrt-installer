# OpenWrt x86_64 Installer — задание для Codex

## ЗАДАЧА

Сделать MVP OpenWrt x86_64 installer, похожий по идее на pfSense installer, но минимальный.

## Цель проекта

Создать репозиторий `openwrt-x86-installer`, который собирает загрузочный OpenWrt-based USB/ISO installer для x86_64.

Этот installer должен:

1. Загружаться с USB/ISO.
2. Показывать shell wizard.
3. Позволять выбрать целевой диск.
4. Позволять выбрать LAN и WAN интерфейсы из списка найденных сетевых карт.
5. Установить заранее собранный OpenWrt x86_64 образ на целевой диск.

Выбор пакетов пользователем пока **не нужен**. Пакеты фиксированные.

## Главная архитектура

1. Есть `installer image` — live OpenWrt, который загружается с USB/ISO.
2. Внутри `installer image` лежит `payload image` — готовый OpenWrt x86_64 target image.
3. Shell installer пишет `payload image` на выбранный SSD/NVMe/SATA диск.
4. Installer расширяет rootfs на весь диск.
5. Installer записывает в установленную систему выбранные LAN/WAN интерфейсы по MAC-адресам.
6. Установленный OpenWrt на первом boot сам находит реальные имена интерфейсов по MAC и применяет UCI-конфигурацию.
7. После reboot пользователь получает минимально рабочий router:
   - LAN через `br-lan`.
   - LAN IP `192.168.1.1/24`.
   - DHCP server на LAN.
   - WAN DHCP client.
   - WAN6 DHCPv6 client.
   - Firewall LAN → WAN.
   - NAT на WAN.
   - LuCI доступен с LAN.

## Важный принцип

Не полагаться на `eth0`/`eth1` напрямую.

В live installer имена интерфейсов могут отличаться от имён после установки. Поэтому выбор LAN/WAN должен сохраняться по MAC-адресам.

Главный принцип:

```text
Installer выбирает LAN/WAN в live-системе,
но установленная система применяет конфигурацию по MAC-адресам на первом boot.
```

`br-lan` создавать обязательно.

---

# 1. Требуемая структура репозитория

Создать структуру:

```text
openwrt-x86-installer/
├── README.md
├── Makefile
├── scripts/
│   ├── build-all.sh
│   ├── build-target.sh
│   ├── build-installer.sh
│   ├── download-openwrt.sh
│   ├── test-qemu-bios.sh
│   └── test-qemu-uefi.sh
├── profiles/
│   ├── packages-target.txt
│   ├── packages-installer.txt
│   └── optional-packages.txt
├── files-target/
│   └── etc/
│       ├── owrt-installer/
│       │   └── README
│       └── uci-defaults/
│           └── 98-installer-network
├── files-installer/
│   ├── etc/
│   │   ├── banner
│   │   ├── inittab
│   │   └── rc.local
│   └── usr/
│       ├── libexec/
│       │   └── owrt-installer-autostart
│       ├── sbin/
│       │   └── owrt-install
│       └── share/
│           └── owrt-installer/
│               ├── manifest.json
│               └── target.img.gz
└── tests/
    ├── qemu/
    └── shellcheck/
```

---

# 2. Сборочные артефакты

После сборки должны получаться:

```text
output/
├── openwrt-x86-64-installer.img.gz
├── openwrt-x86-64-installer.iso        optional, если удобно реализовать
├── openwrt-x86-64-target.img.gz
├── manifest.json
└── sha256sums.txt
```

MVP target image:

```text
x86/64
generic
ext4-combined-efi
```

Причина: `ext4` проще расширять на весь диск через `parted` + `e2fsck` + `resize2fs`.

Позже можно добавить `squashfs-combined-efi`, но не в MVP.

---

# 3. Makefile

Сделать `Makefile`:

```makefile
.PHONY: all target installer clean test shellcheck

all: target installer

target:
	./scripts/build-target.sh

installer:
	./scripts/build-installer.sh

test:
	./scripts/test-qemu-uefi.sh
	./scripts/test-qemu-bios.sh

shellcheck:
	shellcheck files-installer/usr/sbin/owrt-install files-target/etc/uci-defaults/98-installer-network

clean:
	rm -rf build/ output/
```

---

# 4. `packages-target.txt`

Target image — это установленная система OpenWrt.

Минимальный список пакетов:

```text
luci
luci-ssl
uhttpd
rpcd
dropbear
firewall4
nftables
dnsmasq
odhcpd-ipv6only
odhcp6c
ppp
ppp-mod-pppoe
kmod-pppoe
kmod-nft-offload
irqbalance
ethtool
pciutils
usbutils
nano
htop
ca-bundle
curl
wget-ssl
```

Сетевые драйверы:

```text
kmod-e1000
kmod-e1000e
kmod-igb
kmod-igc
kmod-ixgbe
kmod-i40e
kmod-ice
kmod-r8169
kmod-tg3
kmod-bnx2
kmod-bnx2x
kmod-atlantic
```

Storage/USB/NVMe:

```text
kmod-nvme
kmod-ahci
kmod-usb-storage
kmod-usb3
kmod-scsi-core
block-mount
e2fsprogs
resize2fs
parted
fdisk
lsblk
blkid
```

Важно:

Некоторые `kmod`-пакеты могут отсутствовать в конкретной версии OpenWrt. Реализовать optional package handling:

- обязательные пакеты ломают сборку, если отсутствуют;
- optional пакеты логируются как missing и пропускаются.

---

# 5. `packages-installer.txt`

Installer image — это live-система, с которой запускается установка.

Пакеты:

```text
luci
luci-ssl
dropbear
uhttpd
rpcd
firewall4
dnsmasq
odhcpd-ipv6only
odhcp6c

kmod-e1000
kmod-e1000e
kmod-igb
kmod-igc
kmod-ixgbe
kmod-i40e
kmod-ice
kmod-r8169
kmod-tg3
kmod-bnx2
kmod-bnx2x
kmod-atlantic

kmod-nvme
kmod-ahci
kmod-usb-storage
kmod-usb3
kmod-scsi-core

parted
fdisk
e2fsprogs
resize2fs
blkid
lsblk
block-mount
coreutils
coreutils-dd
coreutils-sync
gzip
tar
pciutils
usbutils
ethtool
smartmontools
nano
htop
curl
wget-ssl
ca-bundle
```

Optional:

```text
dialog
bash
tmux
screen
```

Сам installer script писать на POSIX/BusyBox `ash`, не требовать `bash`/`dialog`.

---

# 6. `build-target.sh`

Скрипт должен:

1. Подготовить OpenWrt ImageBuilder или OpenWrt buildroot.
2. Собрать x86/64 generic `ext4-combined-efi` image.
3. Использовать `files-target/` как `FILES` overlay.
4. Использовать `packages-target.txt`.
5. Положить результат в `output/openwrt-x86-64-target.img.gz`.
6. Сгенерировать sha256.

Пример логики:

```sh
TARGET="x86/64"
PROFILE="generic"
IMAGE_TYPE="ext4-combined-efi"
```

Скрипт должен быть аккуратный:

- `set -eu`
- понятные ошибки
- логирование шагов
- проверка наличия нужных команд
- `output` directory создаётся автоматически

---

# 7. `build-installer.sh`

Скрипт должен:

1. Проверить, что target image уже собран.
2. Скопировать target image в:

```text
files-installer/usr/share/owrt-installer/target.img.gz
```

3. Сгенерировать:

```text
files-installer/usr/share/owrt-installer/manifest.json
```

4. `manifest.json` должен содержать:
   - `build_date`
   - `openwrt_version`
   - `target_arch`
   - `target_profile`
   - `image_type`
   - `payload_filename`
   - `payload_sha256`
   - `installer_version`

5. Собрать installer image.
6. Положить результат в `output/openwrt-x86-64-installer.img.gz`.
7. Если удобно, дополнительно собрать ISO, но это optional.

Пример `manifest.json`:

```json
{
  "installer_version": "0.1.0",
  "build_date": "2026-06-02T00:00:00Z",
  "openwrt_version": "snapshot-or-release",
  "target_arch": "x86_64",
  "target_profile": "generic",
  "image_type": "ext4-combined-efi",
  "payload_filename": "target.img.gz",
  "payload_sha256": "..."
}
```

---

# 8. `/etc/banner` для installer

В `files-installer/etc/banner` добавить понятный текст:

```text
OpenWrt x86 Installer

Run:

  owrt-install

This installer will erase the selected target disk.
```

---

# 9. Автозапуск installer

В `files-installer/etc/inittab` installer запускается автоматически на `tty1`:

```text
tty1::respawn:/usr/libexec/owrt-installer-autostart
```

Wrapper `files-installer/usr/libexec/owrt-installer-autostart` один раз запускает:

```text
owrt-install --autostart
```

Перед запуском wrapper:

- выставляет `TERM=linux`, если terminal не задан;
- снижает kernel console loglevel до ошибок;
- ждет, пока список block/net устройств перестанет меняться;
- очищает `tty1`, чтобы первый экран installer не уехал из видимой области.

После выхода из installer на `tty1` открывается обычный login. Serial-консоли остаются ручным входом.

---

# 10. Главный installer script: `/usr/sbin/owrt-install`

Реализовать shell script:

```text
files-installer/usr/sbin/owrt-install
```

Команды:

```text
owrt-install
owrt-install --help
owrt-install --list-disks
owrt-install --list-nics
owrt-install --target /dev/nvme0n1
owrt-install --target /dev/nvme0n1 --lan-mac xx:xx:xx:xx:xx:xx --wan-mac yy:yy:yy:yy:yy:yy
owrt-install --target /dev/nvme0n1 --skip-network-wizard
owrt-install --target /dev/nvme0n1 --allow-removable
owrt-install --target /dev/nvme0n1 --yes-i-know-this-will-erase-data
owrt-install --dry-run
```

---

# 11. `owrt-install`: общий порядок работы

Interactive mode:

1. Показать заголовок и предупреждение.
2. Проверить payload image.
3. Проверить sha256 payload по `manifest.json`.
4. Показать список target disks.
5. Дать выбрать target disk.
6. Показать список network interfaces.
7. Дать выбрать LAN interface.
8. Дать выбрать WAN interface.
9. Запретить выбрать один и тот же интерфейс для LAN и WAN.
10. Показать summary:
    - target disk
    - LAN interface name
    - LAN MAC
    - WAN interface name
    - WAN MAC
    - LAN IP `192.168.1.1/24`
    - WAN DHCP
    - WAN6 DHCPv6
    - NAT enabled
11. Попросить exact confirmation:

```text
ERASE /dev/xxx
```

12. Отключить swap.
13. Unmount всех partitions выбранного target disk.
14. Записать payload на диск.
15. Reread partition table.
16. Найти root partition.
17. Расширить partition 2 до 100%.
18. Выполнить `e2fsck` и `resize2fs`.
19. Смонтировать root partition.
20. Создать `/etc/owrt-installer/interface-map`.
21. Создать `/etc/openwrt-installer-release`.
22. Unmount.
23. `sync`.
24. Предложить:

```text
[1] Reboot now
[2] Shutdown
[3] Return to shell
```

---

# 12. `owrt-install`: safety requirements

Критично:

- Не разрешать установку без явного подтверждения.
- Confirmation phrase должна быть точной:

```text
ERASE /dev/nvme0n1
```

- По умолчанию не разрешать removable disks.
- Если disk `removable=1`, ставить только с `--allow-removable`.
- Не показывать partitions как target disks:
  - показывать `/dev/sda`, но не `/dev/sda1`
  - показывать `/dev/nvme0n1`, но не `/dev/nvme0n1p1`
- Не давать выбрать текущий boot USB как target, если его можно определить.
- Перед `dd` делать:

```sh
swapoff -a || true
```

- Unmount всех mountpoints, принадлежащих target disk.
- Если checksum не совпадает, installation abort.
- Если LAN MAC или WAN MAC пустой, abort.
- Если LAN MAC = WAN MAC, abort.

---

# 13. Обнаружение дисков

Искать диски:

```text
/dev/sd[a-z]
/dev/nvme[0-9]n[0-9]
/dev/vd[a-z]
/dev/xvd[a-z]
/dev/mmcblk[0-9]
```

Для каждого диска показать:

- number
- path
- size
- model
- serial, если доступен
- removable
- rotational
- transport, если доступен

Информацию брать из:

```text
/sys/block/<disk>/size
/sys/block/<disk>/device/model
/sys/block/<disk>/device/serial
/sys/block/<disk>/removable
/sys/block/<disk>/queue/rotational
```

Можно использовать `lsblk`, если доступен, но скрипт должен иметь fallback через `/sys`.

Пример вывода:

```text
Available target disks:

[1] /dev/nvme0n1  238G  Samsung SSD 970 EVO  removable=0  rotational=0
[2] /dev/sda       29G  SanDisk USB           removable=1  rotational=0
[3] /dev/sdb      120G  Intel SSD             removable=0  rotational=0
```

---

# 14. Обнаружение сетевых интерфейсов

Искать интерфейсы через:

```text
/sys/class/net/
```

Исключить:

```text
lo
br-*
docker*
veth*
tun*
tap*
wg*
ppp*
ifb*
gre*
erspan*
ip6tnl*
sit*
```

Для каждого интерфейса показать:

- number
- name
- MAC
- driver
- link state
- speed
- PCI path, если возможно

Функции:

```sh
get_nic_mac() {
    dev="$1"
    cat "/sys/class/net/$dev/address" 2>/dev/null
}

get_nic_driver() {
    dev="$1"
    basename "$(readlink -f "/sys/class/net/$dev/device/driver" 2>/dev/null)" 2>/dev/null || echo "unknown"
}

get_nic_speed() {
    dev="$1"
    cat "/sys/class/net/$dev/speed" 2>/dev/null || echo "unknown"
}

get_nic_link() {
    dev="$1"
    carrier="$(cat "/sys/class/net/$dev/carrier" 2>/dev/null || echo 0)"
    [ "$carrier" = "1" ] && echo "up" || echo "down"
}
```

Пример вывода:

```text
Available network interfaces:

[1] eth0  00:e0:67:12:34:01  driver=igb    link=up    speed=1000
[2] eth1  00:e0:67:12:34:02  driver=igb    link=down  speed=unknown
[3] eth2  a0:36:9f:aa:bb:cc  driver=ixgbe  link=up    speed=10000
```

Interactive prompts:

```text
Select LAN interface:
Select WAN interface:
```

Правила:

- LAN и WAN не могут быть одним интерфейсом.
- Если найден только один интерфейс, network wizard невозможен; показать ошибку или предложить `--skip-network-wizard`.
- Сначала показать список интерфейсов для выбора LAN.
- Если найдено ровно два интерфейса, после выбора LAN автоматически назначить оставшийся интерфейс как WAN.
- Если найдено больше двух интерфейсов, показать оставшиеся интерфейсы и запросить выбор WAN.
- Запросить LAN IPv4/CIDR.
- Запросить WAN mode: DHCP, PPPoE, static IPv4 или disabled.
- Для PPPoE запросить username/password.
- Для static WAN запросить IPv4/CIDR, gateway и DNS.
- Если `--skip-network-wizard`, target остаётся с default network config.

---

# 15. Запись payload image

Payload path:

```text
/usr/share/owrt-installer/target.img.gz
```

Manifest path:

```text
/usr/share/owrt-installer/manifest.json
```

Запись:

```sh
gzip -dc "$PAYLOAD" | dd of="$TARGET" bs=16M conv=fsync status=progress
sync
blockdev --rereadpt "$TARGET" || true
partprobe "$TARGET" || true
sleep 2
```

Если `status=progress` не поддерживается, сделать fallback:

```sh
gzip -dc "$PAYLOAD" | dd of="$TARGET" bs=16M conv=fsync
```

---

# 16. Определение root partition

Для `ext4-combined-efi` считать root partition = partition 2.

Нужно правильно обработать имена:

```text
disk=/dev/sda       root=/dev/sda2
disk=/dev/vda       root=/dev/vda2
disk=/dev/xvda      root=/dev/xvda2
disk=/dev/nvme0n1   root=/dev/nvme0n1p2
disk=/dev/mmcblk0   root=/dev/mmcblk0p2
```

Сделать helper:

```text
get_partition_path "$disk" 2
```

Если disk заканчивается на цифру, добавлять `p` перед номером partition.

---

# 17. Расширение rootfs

Для MVP поддерживать ext4 rootfs.

После записи образа:

```sh
parted -s "$TARGET" resizepart 2 100%
partprobe "$TARGET" || true
sleep 2
e2fsck -f -y "$ROOTPART"
resize2fs "$ROOTPART"
sync
```

Перед resize проверить filesystem:

```sh
blkid -o value -s TYPE "$ROOTPART"
```

Если `TYPE != ext4`:

- не делать `resize2fs`
- показать warning
- для MVP лучше abort, потому что ожидается `ext4-combined-efi`

---

# 18. Запись `interface-map` в установленную систему

После resize:

```sh
mkdir -p /mnt/target
mount "$ROOTPART" /mnt/target
```

Создать:

```text
/mnt/target/etc/owrt-installer/interface-map
```

Содержимое:

```sh
LAN_MAC='xx:xx:xx:xx:xx:xx'
WAN_MAC='yy:yy:yy:yy:yy:yy'
LAN_IP='192.168.1.1'
LAN_NETMASK='255.255.255.0'
WAN_PROTO='dhcp'
WAN6_PROTO='dhcpv6'
```

MAC-адреса писать lowercase.

Если `--skip-network-wizard`, `interface-map` не создавать.

---

# 19. Install marker

Создать файл:

```text
/mnt/target/etc/openwrt-installer-release
```

Пример содержимого:

```text
installed_by=openwrt-x86-installer
installer_version=0.1.0
install_date=2026-06-02T00:00:00Z
target_disk=/dev/nvme0n1
payload_sha256=...
image_type=ext4-combined-efi
lan_mac=...
wan_mac=...
```

---

# 20. First boot script в target: `98-installer-network`

Создать файл:

```text
files-target/etc/uci-defaults/98-installer-network
```

Назначение:

На первом boot установленного OpenWrt прочитать `/etc/owrt-installer/interface-map`, найти реальные имена интерфейсов по MAC-адресам, настроить `network`/`dhcp`/`firewall` через UCI.

Важно: создавать `br-lan` обязательно, даже если LAN только один порт.

Скрипт:

```sh
#!/bin/sh

MAP="/etc/owrt-installer/interface-map"

[ -f "$MAP" ] || exit 0

. "$MAP"

lower() {
    echo "$1" | tr 'A-F' 'a-f'
}

find_dev_by_mac() {
    wanted="$(lower "$1")"

    for devpath in /sys/class/net/*; do
        name="$(basename "$devpath")"

        case "$name" in
            lo|br-*|docker*|veth*|tun*|tap*|wg*|ppp*|ifb*|gre*|erspan*|ip6tnl*|sit*)
                continue
                ;;
        esac

        [ -f "$devpath/address" ] || continue

        mac="$(lower "$(cat "$devpath/address" 2>/dev/null)")"

        if [ "$mac" = "$wanted" ]; then
            echo "$name"
            return 0
        fi
    done

    return 1
}

LAN_DEV="$(find_dev_by_mac "$LAN_MAC")"
WAN_DEV="$(find_dev_by_mac "$WAN_MAC")"

if [ -z "$LAN_DEV" ] || [ -z "$WAN_DEV" ]; then
    logger -t owrt-installer "Could not map LAN/WAN MACs to device names"
    exit 1
fi

if [ "$LAN_DEV" = "$WAN_DEV" ]; then
    logger -t owrt-installer "LAN and WAN resolved to the same device, aborting"
    exit 1
fi

logger -t owrt-installer "Mapping complete: LAN=$LAN_DEV WAN=$WAN_DEV"

uci -q batch <<EOF_UCI_NETWORK
delete network.lan
delete network.wan
delete network.wan6
delete network.br_lan

set network.br_lan=device
set network.br_lan.name='br-lan'
set network.br_lan.type='bridge'
add_list network.br_lan.ports='$LAN_DEV'

set network.lan=interface
set network.lan.device='br-lan'
set network.lan.proto='static'
set network.lan.ipaddr='${LAN_IP:-192.168.1.1}'
set network.lan.netmask='${LAN_NETMASK:-255.255.255.0}'

set network.wan=interface
set network.wan.device='$WAN_DEV'
set network.wan.proto='${WAN_PROTO:-dhcp}'

set network.wan6=interface
set network.wan6.device='$WAN_DEV'
set network.wan6.proto='${WAN6_PROTO:-dhcpv6}'

commit network
EOF_UCI_NETWORK

uci -q batch <<EOF_UCI_DHCP
delete dhcp.lan
delete dhcp.wan

set dhcp.lan=dhcp
set dhcp.lan.interface='lan'
set dhcp.lan.start='100'
set dhcp.lan.limit='150'
set dhcp.lan.leasetime='12h'

set dhcp.wan=dhcp
set dhcp.wan.interface='wan'
set dhcp.wan.ignore='1'

commit dhcp
EOF_UCI_DHCP

# Recreate minimal firewall zones.
# Be careful: UCI delete by index can shift entries.
# For MVP, remove known default sections by name where possible.

while uci -q delete firewall.@forwarding[0]; do :; done
while uci -q delete firewall.@zone[0]; do :; done

uci -q batch <<EOF_UCI_FIREWALL
add firewall zone
set firewall.@zone[-1].name='lan'
set firewall.@zone[-1].input='ACCEPT'
set firewall.@zone[-1].output='ACCEPT'
set firewall.@zone[-1].forward='ACCEPT'
add_list firewall.@zone[-1].network='lan'

add firewall zone
set firewall.@zone[-1].name='wan'
set firewall.@zone[-1].input='REJECT'
set firewall.@zone[-1].output='ACCEPT'
set firewall.@zone[-1].forward='REJECT'
set firewall.@zone[-1].masq='1'
set firewall.@zone[-1].mtu_fix='1'
add_list firewall.@zone[-1].network='wan'
add_list firewall.@zone[-1].network='wan6'

add firewall forwarding
set firewall.@forwarding[-1].src='lan'
set firewall.@forwarding[-1].dest='wan'

commit firewall
EOF_UCI_FIREWALL

logger -t owrt-installer "Configured minimal router: br-lan=$LAN_DEV, wan=$WAN_DEV"

exit 0
```

---

# 21. Важное замечание по firewall script

Если в дефолтном OpenWrt firewall уже есть нужные zones, можно не удалять весь firewall, а аккуратно обновить существующие зоны по имени.

Лучше реализовать helper-функции:

```text
ensure_firewall_zone_lan()
ensure_firewall_zone_wan()
ensure_lan_to_wan_forwarding()
```

Но для MVP допустимо пересоздать firewall полностью, если это чистый target image.

---

# 22. `README.md`

`README.md` должен описывать:

- Что делает проект.
- Что это MVP.
- Что поддерживается только x86_64.
- Что installation стирает выбранный диск.
- Как собрать:

```sh
make all
```

- Как собрать только target:

```sh
make target
```

- Как собрать installer:

```sh
make installer
```

- Как записать installer USB:

```sh
gzip -dc output/openwrt-x86-64-installer.img.gz | dd of=/dev/sdX bs=16M conv=fsync
```

- Как загрузиться.
- Как запустить:

```sh
owrt-install
```

- Как проверить список дисков:

```sh
owrt-install --list-disks
```

- Как проверить список NIC:

```sh
owrt-install --list-nics
```

- Как сделать unattended/minimal:

```sh
owrt-install --target /dev/nvme0n1 \
  --lan-mac xx:xx:xx:xx:xx:xx \
  --wan-mac yy:yy:yy:yy:yy:yy \
  --yes-i-know-this-will-erase-data
```

`README.md` должен явно предупреждать:

- выбранный диск будет полностью уничтожен;
- не выбирать installer USB как target;
- removable disks заблокированы по умолчанию.

---

# 23. QEMU tests

Сделать `test-qemu-uefi.sh`.

Сценарий:

1. Создать empty disk image:

```sh
qemu-img create -f qcow2 build/test-target.qcow2 4G
```

2. Загрузить installer image через QEMU + OVMF.
3. Подключить empty disk как virtio disk.
4. По возможности автоматизировать запуск:

```sh
owrt-install --target /dev/vda \
  --lan-mac ... \
  --wan-mac ... \
  --yes-i-know-this-will-erase-data
```

5. После установки загрузиться с `/dev/vda`.
6. Проверить, что OpenWrt booted.
7. Проверить, что `/etc/openwrt-installer-release` существует.
8. Проверить, что rootfs расширен.

Сделать `test-qemu-bios.sh`.

То же самое, но legacy BIOS mode.

Если полная автоматизация сложная, сделать scripts как semi-manual tests с понятными инструкциями.

---

# 24. Shell quality

Требования к shell scripts:

- POSIX sh / BusyBox ash compatible.
- `set -eu`, где возможно.
- Не использовать bash-only features.
- Все переменные в кавычках.
- Аккуратная обработка ошибок.
- Понятные сообщения пользователю.
- Shellcheck clean, насколько возможно.
- Логировать важные события через `logger -t owrt-installer`, если `logger` доступен.

---

# 25. Не делать в MVP

Пока **не делать**:

- выбор пакетов пользователем
- web installer
- LuCI wizard
- PPPoE credentials wizard
- VLAN wizard
- multiple LAN ports
- bridge всех невыбранных портов
- automatic WAN detection
- static WAN IP
- Wi-Fi setup
- backup import
- config migration
- encrypted install
- Secure Boot
- ZFS/Btrfs
- A/B partitions
- unattended config file на USB

---

# 26. Будущая версия, но не сейчас

Архитектуру оставить такой, чтобы потом можно было добавить:

```sh
LAN_MACS='mac1 mac2 mac3'
WAN_PROTO='pppoe'
WAN_USERNAME='...'
WAN_PASSWORD='...'
```

Также потом можно добавить:

- VLAN interfaces
- import backup config from USB
- serial console friendly mode
- web-based LuCI installer
- unattended config file:

```text
/boot/owrt-installer.conf
```

Пример будущего config:

```ini
target=/dev/nvme0n1
resize_rootfs=1
lan_macs='00:11:22:33:44:55 00:11:22:33:44:66'
wan_mac='00:11:22:33:44:77'
lan_ip='192.168.1.1'
wan_proto='dhcp'
confirm_erase='YES'
```

---

# 27. Definition of Done для MVP

MVP считается готовым, если:

1. `make all` создаёт target image и installer image.
2. Installer image загружается в QEMU.
3. В installer доступна команда `owrt-install`.
4. `owrt-install --list-disks` показывает диски.
5. `owrt-install --list-nics` показывает сетевые интерфейсы.
6. Interactive install позволяет выбрать disk, LAN, WAN.
7. Installer не позволяет выбрать один интерфейс как LAN и WAN.
8. Installer требует exact confirmation `ERASE /dev/xxx`.
9. Installer пишет target image на диск.
10. Installer расширяет ext4 rootfs на весь диск.
11. Installer записывает `/etc/owrt-installer/interface-map` в установленную систему.
12. После reboot установленный OpenWrt создаёт `br-lan`.
13. LAN interface включён в `br-lan`.
14. LAN получает `192.168.1.1/24`.
15. DHCP server работает на LAN.
16. WAN работает как DHCP client.
17. WAN6 работает как DHCPv6 client.
18. Firewall содержит `lan zone`, `wan zone`, NAT и forwarding `lan → wan`.
19. LuCI доступен с LAN.
20. `/etc/openwrt-installer-release` существует.
21. README содержит инструкции по сборке, записи USB и установке.

---

# Финальное резюме для Codex

Сделать минимальный, но безопасный OpenWrt x86_64 installer.

Самое важное:

1. Installer live image содержит готовый payload image.
2. Installer пишет payload на выбранный диск.
3. Installer расширяет ext4 rootfs.
4. Installer даёт выбрать LAN/WAN.
5. Выбор LAN/WAN сохраняется по MAC-адресам.
6. Target OpenWrt на первом boot создаёт `br-lan`, настраивает LAN/WAN/DHCP/firewall/NAT.
7. Не делать пока сложные features вроде PPPoE wizard, VLAN, web UI, backup import и выбора пакетов.
