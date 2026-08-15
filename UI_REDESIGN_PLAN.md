# OpenWrt Hellforge Installer UI Plan

Дата: 2026-08-12.

Цель: сделать shell installer менее скучным, но не превратить его в тяжелый live-дистрибутив. Визуальное направление: темная консоль, жесткие ASCII-рамки, красно-янтарные warning-секции, аккуратные progress bars в духе DOS-инсталлеров и понятная логика уровня IPFire. Doom-брендинг, названия, графика и ассеты не использовать.

## Короткий вывод

Реализованный путь: обязательный `whiptail`/newt backend для локальной Linux console, ANSI/POSIX shell backend с native SGR mouse для SSH/xterm-compatible terminals, line fallback для serial/pipe и optional `dialog` backend там, где пакет доступен. Unified candidate entry включает local VGA mouse через штатный Linux `mousedev` aggregate `/dev/input/mice` и GPM `imps2`, без project-owned parser для `EV_REL`/`EV_ABS`; публикация остается заблокирована physical gate.

Mouse support не является обязательным для прохождения wizard. В локальной Linux console `tty1` мышь обычно не работает как terminal event без `gpm` или прямой обработки `/dev/input/event*`. В SSH/xterm-подобных терминалах SGR mouse reporting работает без дополнительных пакетов. Поэтому базовая UX-модель остается keyboard-first, а мышь дублирует те же безопасные действия.

## Принципы

- Безопасность важнее красоты: destructive flow, `ERASE /dev/...`, проверка payload SHA-256 и disk guards не ослаблять.
- Non-interactive CLI должен остаться стабильным: `--target`, `--lan-mac`, `--wan-mac`, `--lan-ip`, `--skip-network-wizard`, `--yes-i-know-this-will-erase-data`.
- Serial/pipe fallback обязателен: если нет нормальной TTY, остаются простые numbered prompts.
- Использовать небольшой официальный пакет `whiptail` как обязательный local-console backend. `dialog` оставить optional backend, а ANSI/line fallback не удалять.
- ASCII default. UTF-8 box drawing можно добавить позже как опцию, но не делать базой из-за VGA/serial/font рисков.
- Все raw terminal modes должны восстанавливаться через `trap`: cursor visible, mouse off, `stty` restored.
- Native mouse tracking включать только на время ANSI menu и только для известных xterm-compatible `TERM`; `TERM=linux` и serial не включать.

## Визуальная Спецификация

Рабочее имя интерфейса: `OpenWrt Hellforge Installer`.

Палитра:

- фон: черный или почти черный;
- основной текст: ярко-серый/белый;
- рамки: cyan/steel;
- активный пункт: amber/yellow на темном фоне или reverse video;
- опасные действия: red + bold;
- успех: green;
- вторичный текст: dim gray.

Базовый layout для 80x25:

```text
+------------------------------------------------------------------------------+
| OPENWRT HELLFORGE INSTALLER                                      v1.0-alpha.7 |
+------------------------------------------------------------------------------+
| Steps: [1 Disk] -> [2 LAN] -> [3 WAN] -> [4 Review] -> [5 Install]            |
+------------------------------------------------------------------------------+
| Select Target Disk                                                            |
|                                                                              |
|  > /dev/sda    119.2G  Samsung SSD  removable=no  live=no                    |
|    /dev/nvme0n1 476.9G  NVMe Disk    removable=no  live=no                    |
|                                                                              |
| WARNING: selected disk will be erased after final confirmation.               |
+------------------------------------------------------------------------------+
| Up/Down Move  Enter Select  Esc Back  F10 Shell/Reboot                         |
+------------------------------------------------------------------------------+
```

Никаких декоративных ASCII-art экранов на важных шагах. Стиль должен помогать сканировать выбор, а не прятать информацию.

## Архитектура UI

Текущий `files-installer/usr/sbin/owrt-install` уже имеет точки входа:

- `menu_reset`, `menu_note`, `menu_add`;
- `render_numbered_menu`, `render_arrow_menu`;
- `select_from_menu`;
- `prompt_default`;
- `show_summary`;
- `confirm_erase`;
- `write_payload`, `resize_rootfs`, `post_install_menu`.

Планируемый слой:

```text
owrt-install
  |
  +-- ui backend selector
      |
      +-- line backend       current numbered prompts / CI / non-TTY
      +-- ansi backend       SSH/xterm TUI with native SGR mouse
      +-- whiptail backend   packaged local Linux-console curses UI
      +-- dialog backend     optional mouse-capable backend when dialog exists
```

Предлагаемые shell-функции:

```text
ui_detect
ui_enter
ui_leave
ui_clear
ui_frame
ui_header
ui_steps
ui_footer
ui_menu
ui_input
ui_password
ui_warning
ui_summary
ui_progress
ui_post_install_menu
```

Переключатели окружения:

```text
OWRT_UI_MODE=auto|line|ansi|whiptail|curses|dialog
OWRT_UI_THEME=hellforge
OWRT_UI_FORCE_ASCII=1
OWRT_UI_NO_MOUSE=1
OWRT_UI_DEBUG=1
```

## Фаза 0: Подготовка Без Изменения Поведения

Цель: подготовить проект так, чтобы UI можно было менять без риска сломать installation flow.

Работы:

- Вынести UI helpers в отдельный shell-файл, например `files-installer/usr/libexec/owrt-installer-ui`.
- В `owrt-install` оставить бизнес-логику: disk discovery, network selection, validation, write/resize/config.
- Добавить source нового UI-файла с fallback, если файл не найден.
- Сохранить текущие функции как line backend.
- Добавить `OWRT_UI_MODE=line` для тестов.
- Расширить `make shellcheck`, чтобы проверял новый UI-файл.

Критерии приемки:

- `make syntax-check` проходит.
- `make shellcheck` проходит.
- При `OWRT_UI_MODE=line` поведение меню совпадает с текущим.
- Non-interactive arguments не затронуты.

## Фаза 1: ANSI Hellforge TUI

Цель: сделать первый современный полноэкранный TUI без новых пакетов.

Работы:

- Реализовать `ansi` backend:
  - очистка экрана;
  - скрытие курсора на время меню;
  - header bar;
  - step bar;
  - main frame;
  - footer hotkeys;
  - warning block;
  - highlighted selection.
- Перевести следующие экраны:
  - welcome/system check;
  - disk selection;
  - LAN selection;
  - auto WAN selected notice;
  - WAN selection;
  - LAN IP form;
  - WAN IPv4 mode/form;
  - WAN IPv6 mode;
  - review screen;
  - final erase confirmation;
  - post-install action screen.
- Добавить `Esc` как controlled cancel/back там, где это безопасно.
- Для narrow terminal меньше 80x24 включать line backend или compact layout.

Критерии приемки:

- На `tty1` в QEMU BIOS и UEFI TUI помещается в экран.
- Kernel/info messages не ломают prompt после autostart.
- На serial console нет бесконечного мерцания и escape-мусора.
- `Ctrl+C` не оставляет терминал в raw mode.

## Фаза 2: Формы И Review

Цель: сделать ввод IP/WAN понятным и проверяемым до записи диска.

Текущий статус на 2026-08-12: structured forms и полноценный form-level Back реализованы без новых зависимостей. `prompt_default` и `prompt_secret` показывают context, example, current/default и error zone. В ANSI form `Esc` возвращает на предыдущий шаг, `dialog` Cancel делает то же самое, line fallback использует `!back` с escape `!!back` для literal value. WAN mode и WAN6 menus содержат явные Back items. PPPoE/static state machine возвращается по одному полю, сохраняет уже введенные значения во время редактирования и очищает credentials/settings невыбранного протокола перед review. Ошибки валидации возвращают только к текущему полю; PPPoE password не попадает в review и стирается из shell variable при cleanup.

Дополнение на 2026-08-12: добавлен безопасный review action loop перед финальным `ERASE`. Пользователь может продолжить к точному destructive confirmation, заново пройти выбор LAN/WAN и network settings или отменить установку. Это не запускает запись диска с review screen напрямую.

Работы:

- Заменить отдельные prompts на structured form screens:
  - LAN IPv4/CIDR;
  - WAN mode;
  - PPPoE username/password;
  - static WAN IPv4/CIDR, gateway, DNS;
  - WAN IPv6 mode.
- На каждом form screen показывать:
  - текущий default;
  - пример корректного формата;
  - ошибку в отдельной red warning zone;
  - возможность вернуться назад.
- Review screen должен показывать:
  - target disk model/size;
  - LAN/WAN device and MAC;
  - LAN IP;
  - WAN IPv4;
  - WAN IPv6;
  - NAT status;
  - exact confirmation string.

Критерии приемки:

- Ошибки валидации не сбрасывают весь wizard.
- Password для PPPoE не отображается в summary.
- PPPoE + WAN6 DHCPv6/PD объясняется короткой note, без отдельного невалидного PPPoE IPv6 выбора.

## Фаза 3: Progress И Install Log

Цель: заменить голый `dd status=progress` на спокойный progress screen.

Текущий статус на 2026-08-12: реализован stage-based progress screen для
установки на диск. Runtime output служебных команд уходит в
`/tmp/owrt-installer.log`, TUI показывает текущий этап, DOS-style progress bar
и compact log pane на 3-5 строк. Ошибки проходят через отдельный failure
screen с log path и хвостом лога. `manifest.json` содержит
`payload_uncompressed_size`, а обязательный официальный `pv 1.9.31` дает
честный byte-percent во время записи payload. Native curses использует gauge;
ANSI и line backend отображают тот же numeric stream. При отсутствии точного
размера или `pv` остается stage-only fallback.

Дополнение для `v1.0-alpha.7`: официальный пакет `pv 1.9.31` из OpenWrt
`25.12` x86_64 feed заменяет статический `Write image` screen на честный
byte-percent. `gzip`, `pv` и `dd` запускаются
как три отдельно отслеживаемых процесса через data FIFOs; numeric progress
идет по отдельному FIFO в native curses gauge или ANSI/line renderer. Это
позволяет получить status каждого процесса через `wait PID`, завершить все
дочерние процессы при interrupt и не зависеть от отсутствующего POSIX
`pipefail`.

Работы:

- Добавить progress screen с этапами:
  1. verify payload;
  2. unmount target partitions;
  3. write image;
  4. reread partition table;
  5. grow partition;
  6. e2fsck;
  7. resize2fs;
  8. write installed config;
  9. sync.
- Для `write image` добавить более аккуратный progress:
  - preferred: добавить uncompressed payload size в `manifest.json` на build host;
  - fallback: показывать spinner/log если точный процент недоступен;
  - не полагаться только на `dd status=progress`, потому что формат вывода может различаться.
- Внизу оставить compact log pane на 3-5 строк.

Критерии приемки:

- Пользователь видит текущий этап и понимает, что система не зависла.
- Ошибка на любом этапе отображается в отдельном failure screen.
- В failure screen есть `Return to shell` и краткая подсказка, где смотреть лог.

## Фаза 4: Curses Backend И Мышь

Цель: добавить mouse-friendly backend без зависимости от него.

Текущий статус на 2026-08-12: официальный `whiptail 0.52.24` добавлен в installer image как обязательный пакет и является стандартным backend на локальной `TERM=linux` console. Общая curses-абстракция безопасно передает menu arguments без `eval`, проверяет работоспособность команды через `--version` и поддерживает menu/input/password/message/progress widgets. `OWRT_UI_MODE=curses` выбирает `dialog`, затем `whiptail`, затем ANSI; принудительные `whiptail` и `dialog` modes также доступны. В auto mode `dialog` имеет приоритет, локальная Linux console использует `whiptail`, а SSH/xterm остается на ANSI ради native SGR mouse. Пакет `dialog` в текущем OpenWrt `25.12.5` feed отсутствует и остается optional.

Дополнение на 2026-08-12: в ANSI backend реализован native SGR mouse без новых зависимостей. В SSH/xterm-compatible terminals direct left click выбирает видимый menu item, wheel меняет выделение, а клавиатурные Up/Down/Enter продолжают работать всегда. Tracking `1000`/`1006` включается только внутри menu loop и выключается при выборе, отмене, `Ctrl+C` и общем cleanup. `OWRT_UI_NO_MOUSE=1`, local `TERM=linux` и serial оставляют keyboard-only flow.

Дополнение на 2026-08-13 для local VGA mouse: QEMU probe текущего ISO показал,
что USB tablet распознается input core, но не получает handler, `/dev/input`
не создается. В ImageBuilder доступен штатный `kmod-input-evdev`, поэтому kernel
пересобирать не требуется. Официальный OpenWrt package `newt 0.52.24` явно
собран с `--without-gpm-support`, хотя upstream newt содержит GPM protocol
client и coordinate-aware mouse handling. Выбранный prototype path:

- добавить `kmod-input-evdev` только в installer image;
- собирать drop-in packages `libnewt`/`whiptail` с GPM support через
  официальный OpenWrt `25.12.5` SDK, не подменяя host binaries;
- собирать daemon-only вариант upstream `gpm 1.20.7`: без legacy clients,
  kernel selection/paste objects и world-writable control socket; musl/GCC
  compatibility patches остаются локальными и воспроизводимыми;
- project-owned shell helper выбирает только evdev devices с `REL_X` и
  `REL_Y`, запускает GPM на local `tty1` и проверяет socket mode `0600`;
- не использовать `TIOCSTI`, `uinput`, key injection или shell parsing binary
  input events;
- запускать daemon только на local `tty1`, оставляя SSH/serial и keyboard flow
  независимыми.

Дополнение на 2026-08-14 после VMware retest: прямой выбор
`/dev/input/event*`, downstream `EV_ABS` decoder и специальная маршрутизация
VMware twin devices удалены. Installer теперь собирает из точного Linux
`6.12.87` source штатный `mousedev.ko`, получает единый PS/2-compatible stream
через `/dev/input/mice` и запускает GPM с типом `imps2`. Newt рисует видимый
selection-cell pointer через стандартный `TIOCLINUX`; blinking text caret не
перемещается. Этот путь прошел USB relative, PS/2, absolute USB tablet и
exact-confirmation QEMU matrix, после чего движение и выбор были вручную
подтверждены в VMware. Путь включен в unified candidate entry по решению для
трехпунктового GRUB, но не считается release-ready до bare-metal gate.

Threat model local mouse:

- mouse events считаются недоверенным локальным navigation input, эквивалентным
  стрелкам/Enter, и не могут ввести обязательную строку `ERASE /dev/...`;
- daemon открывает только фиксированный kernel aggregate `/dev/input/mice`;
  helper не выбирает `eventX`, не декодирует binary input events и не принимает
  device path из network/user input;
- `/dev/gpmctl` принудительно создается с mode `0600` и повторно проверяется
  helper после старта;
- GPM полностью останавливается после выхода предыдущего Newt widget и до
  keyboard-only ввода точной destructive phrase `ERASE /dev/...`;
- daemon завершается и удаляет socket при выходе installer; failure мыши не
  прерывает keyboard UX;
- unified GRUB entry передает `owrt.mouse=1`, а ручной запуск использует
  `OWRT_LOCAL_MOUSE_ENABLE=1`; QEMU/VMware gates пройдены, но feature не
  объявлять поддерживаемой и не публиковать candidate до отдельной проверки на
  физической x86 машине.

Работы:

- Если `OWRT_UI_MODE=dialog` или `OWRT_UI_MODE=auto` и `dialog` доступен:
  - генерировать `/tmp/owrt-installer.dialogrc`;
  - выставлять `DIALOGRC`;
  - использовать `dialog --menu`, `--radiolist`, `--inputbox`, `--passwordbox`, `--yesno`, `--gauge`;
  - включать `--mouse`, если не задан `OWRT_UI_NO_MOUSE=1`.
- Если выбранный curses command отсутствует или не работает, fallback на `ansi`; serial/pipe остается на line UI.
- Для `whiptail` применять Hellforge `NEWT_COLORS`, full-width buttons и компактные disk labels, чтобы layout помещался в `80x24`.
- Для локальной VGA console мышь считать experimental: проверить отдельно, не обещать как гарантированную функцию.
- Для ANSI backend использовать SGR mouse reporting только на совместимых terminal emulators; click должен вызывать тот же selection path, что Enter.

Ограничение:

- `dialog --mouse` обычно работает там, где терминал передает mouse events. Обычная Linux console `tty1` часто этого не делает.
- Для настоящей мыши на VGA потребуется `gpm` или прямой evdev parser. Это отдельная фаза и отдельный риск.

Критерии приемки:

- Keyboard flow работает всегда.
- Mouse click работает в SSH/xterm-подобном терминале через native ANSI SGR protocol; `dialog --mouse` остается optional альтернативой.
- При отсутствии мыши UI не деградирует.

## Фаза 5: QEMU И Regression Tests

Цель: не выпускать красивый, но хрупкий installer.

Текущий статус на 2026-08-12: матрица Hellforge ANSI/whiptail пройдена. Новый hybrid ISO собран через `make iso`, `sha256sum -c output/sha256sums.txt` проходит, initramfs содержит актуальные `usr/sbin/owrt-install`, `usr/libexec/owrt-installer-ui`, исполняемые `whiptail 0.52.24` и `pv 1.9.31`; runtime `INSTALLER_VERSION=v1.0-alpha.7`. Текущий локальный ISO SHA-256: `89f9e2c89df7fe27f882d1d2db7114caefff226ad840b70b92b1205458ddfa7c`; `v1.0-alpha.7` опубликован отдельным alpha tag, старые alpha tags не двигаются. BIOS и UEFI QEMU smoke-test проверяют GRUB, kernel/initramfs, OpenWrt serial console, backend marker и автозапуск wizard. VGA smoke дожидается реального target-disk menu, делает PPM framebuffer dump и проверяет, что экран не пуст. Автоматический install smoke проходит весь wizard, проверяет numeric write-progress до `100`, устанавливает образ на одноразовый qcow2, загружает установленный OpenWrt и сверяет `/etc/openwrt-installer-release`. `make ui-smoke` дополнительно управляет настоящим host `whiptail` через pseudo-TTY: arrow selection, input editing, Esc/Back, скрытый password, shell-metacharacter safety, theme и backend fallback/precedence. `make install-flow-smoke` проверяет destructive guards, network state machine, byte-identical payload write, failure status и очистку FIFO, а `make smoke` объединяет быстрые non-ISO проверки.

Дополнение на 2026-08-14: прежний direct-evdev prototype заменен штатным Linux
`mousedev` aggregate. Полный `make mouse-qemu-smoke` проверяет USB relative,
PS/2, absolute USB tablet, видимый console pointer, продолжение keyboard flow
после принудительного завершения GPM, остановку daemon до exact `ERASE`, mode
`0600` и удаление socket/PID/state. Ручной VMware retest также пройден. Этот
mouse-specific `v1.0-alpha.9-dev` build имел SHA-256
`4cbde5e14686115df0d3aa9543ec4f79b580b4cbe2e34248d78b2ed2a904c804`.
Более новый final dev ISO с неизмененным mouse path зафиксирован в Phase 7;
публикация/default по-прежнему ждут отдельный physical x86 gate.

Дополнение по online install: opt-in GRUB path полностью прошел deterministic
failure matrix и реальные QEMU download/install/installed-boot acceptance для
BIOS и UEFI. В обоих случаях 2026-08-14 была обнаружена и проверена официальная
stable версия OpenWrt `25.12.5`. Базовый `make iso-smoke` после изменений также
прошел целиком. Для воспроизводимой сборки `scripts/common.sh` теперь явно
задает `umask 022`; это предотвращает создание rootfs с правами `0700/0600` на
runner-ах с исходной `umask 077` и покрыто `make build-env-smoke`.

Финальный frozen `v1.0-alpha.8` release candidate из runtime commit `964fed6`
имеет SHA-256
`f1131d7587d49b5accf0e1e6b96fc378114fd1f9293a7e1e1a0e5dc1772a22e5`.
На нем повторно прошли `make smoke`, `make mouse-qemu-smoke` и полный
`make iso-smoke`: BIOS, UEFI, VGA framebuffer, весь wizard, запись на
одноразовый target disk и загрузка установленного `v1.0-alpha.8` OpenWrt.
Daemon-crash path дополнительно удаляет stale socket/PID/state внутри гостевой
OpenWrt и сохраняет keyboard flow. Публикация release намеренно отложена до
задачи 37.

Безопасная подготовка к physical gate завершена: второй GRUB entry принудительно
передает `owrt.mouse=1 owrt.hardware-test=1`, autostart преобразует его в
`--dry-run`, UI явно маркирует все опасные экраны как safe dry-run, а
`owrt-hardware-report` собирает privacy-safe результат. QEMU выбирает этот пункт
в настоящем ISO, проходит exact confirmation и подтверждает полную неизменность
target disk по SHA-256. Обычный default entry и destructive install-to-disk
после изменения также повторно прошли acceptance.

Минимальная матрица:

- `make syntax-check`;
- `make shellcheck`;
- smoke tests для `OWRT_UI_MODE=line`;
- smoke tests для `OWRT_UI_MODE=ansi` с synthetic key input;
- QEMU BIOS ISO boot;
- QEMU UEFI ISO boot;
- QEMU serial/headless smoke test;
- проверка autostart на `tty1`;
- проверка `--skip-network-wizard`;
- проверка `--dry-run`;
- проверка Ctrl+C cleanup в интерактивном меню.
- проверка Esc cancel в интерактивном меню.

Дополнительно:

- ANSI snapshot test: рендер меню в temp TTY или captured output, затем strip ANSI и проверка ключевых строк.
- Проверка terminal size: 80x25, 80x24, 80x23, 100x30, слишком узкий экран.
- Проверка packaged whiptail backend в live image и настоящего dialog backend, когда его package станет доступен.

## Фаза 6: Документация И Release

Работы:

- Обновить `README.md`:
  - показать, что installer autostarts;
  - описать keyboard controls;
  - честно указать mouse support как optional/terminal-dependent.
- Обновить `WORK_SUMMARY.md`.
- Обновить `LOCAL_CONTEXT.md` без секретов.
- После сборки ISO обновить SHA-256.
- Новый release делать отдельным тегом, не двигать старые alpha tags.

## Online Combined Image Install

Статус на 2026-08-15: verified download engine встроен в unified installer.
Main entry проверяет official stable, предлагает download только для строго
более новой версии и автоматически продолжает с embedded image без сети или
при equal/older stable. Принудительный `owrt.netinstall=1` сохранен как скрытый
diagnostic/QEMU path:

1. Проверить уже существующий маршрут, DNS и HTTPS-доступ к официальному
   OpenWrt download host. Если сети нет, предложить выбрать uplink и повторно
   использовать текущие DHCP/static/PPPoE primitives; любой отказ возвращает к
   встроенному payload.
2. Получить подписанные official stable release metadata. Не использовать
   snapshot и не доверять одному только слову `latest` или checksum, полученной
   с того же URL: manifest/checksum signature проверяется встроенным pinned
   OpenWrt release key и минимальным verifier package.
3. Выбрать только `x86/64 generic ext4` image по текущему boot mode:
   `generic-ext4-combined-efi.img.gz` для UEFI и
   `generic-ext4-combined.img.gz` для BIOS. Не подставлять wildcard, который
   может выбрать squashfs/targz: ext4 сохраняет ожидаемый post-install
   configuration path.
4. До загрузки сравнить `MemAvailable` с размером compressed image плюс
   фиксированным резервом installer runtime. Download идет в отдельный RAM/tmpfs
   файл с ограничением размера; при нехватке памяти запись на target disk не
   начинается и предлагается встроенный payload. Прямая network-to-disk
   streaming installation остается отдельной будущей задачей.
5. Проверить TLS, signature, SHA-256, gzip integrity, x86_64 image layout и
   ожидаемый combined partition table. Только после всех проверок передать
   локальный RAM payload существующему disk/review/exact `ERASE`/write flow.
6. На review явно показать source=`downloaded official OpenWrt`, точную версию,
   filename, SHA-256, boot mode и RAM usage. Любая ошибка сети или проверки
   должна быть recoverable и не оставлять partial payload или измененный disk.

Acceptance для этой функции: offline fallback, captive portal/DNS/TLS failure,
bad signature, checksum mismatch, truncated gzip, wrong architecture/layout,
insufficient RAM, BIOS/UEFI selection, successful QEMU download/install/boot и
доказательство отсутствия disk writes до exact confirmation.

Этапы реализации:

1. [done] Добавить GRUB flag, pinned official OpenWrt usign key и общую
   payload-source metadata модель.
2. [done] Добавить existing-connectivity probe и временный DHCP/static/PPPoE
   bootstrap с восстановлением live RAM network config.
3. [done] Реализовать signed stable metadata, exact x86/64 filename,
   Content-Length/RAM gate, bounded download, SHA-256, gzip и partition-layout
   checks.
4. [done] Показывать source/version/filename/hash/boot mode/RAM usage в
   review и переиспользовать единственный existing ERASE/write/resize/config
   path.
5. [done] Добавить deterministic source-level failure matrix и реальный QEMU
   online download/install/installed-boot acceptance.

## Phase 7: Import OpenWrt Configuration From USB

Статус на 2026-08-15: implemented, fixed and verified in frozen
`v1.0-alpha.9`. Эта фаза не зависит от незакрытого physical mouse gate и не
меняет его статус. Candidate hybrid ISO имеет SHA-256
`2b570a2e5747b0a9f2cd46c8252059dd64f101d35c0e14c06fdb69402cffd851`.

После выбора target disk интерактивный wizard предлагает:

1. `Clean installation` — существующий LAN/WAN wizard.
2. `Import OpenWrt backup from USB` — read-only поиск штатного
   `sysupgrade -b` архива `.tar.gz`/`.tgz` и восстановление после записи image.
3. `Back to target disk selection` — без mount, RAM-copy или disk write.

Политика импорта:

- USB partition монтируется только `ro,nosuid,nodev,noexec`; ext4 дополнительно
  использует `noload`. Поддерживаются FAT32, exFAT, NTFS3 и ext4.
- Выбранный архив копируется в private RAM workspace до review, после чего USB
  немедленно размонтируется. SHA-256 считается только от RAM-copy.
- Лимиты: не более 64 MiB compressed, 128 MiB unpacked, 8192 members и 32 MiB
  на один member. До RAM-copy учитывается `MemAvailable` плюс фиксированный
  резерв installer runtime.
- Разрешены только безопасные relative ASCII paths под `etc/`, обычные файлы и
  directories. Absolute/traversal paths, `./`, `//`, backslash, control chars,
  links, devices, sockets, FIFO, setuid/setgid и неоднозначный tar listing
  отклоняют весь архив.
- Extract выполняется только в пустой `0700` RAM staging directory. После
  extraction повторно проверяются реальные file types, paths, modes, member
  count и size; tar никогда не распаковывается напрямую в target rootfs.
- Scope `Configuration only (recommended)` переносит только `etc/config/`.
  Scope `Full OpenWrt backup (advanced)` переносит все проверенные `etc/`
  entries и требует отдельного warning, поскольку может восстановить root
  password, SSH keys и first-boot executable configuration.
- `etc/backup/installed_packages.txt` показывается как metadata, но package
  installation из него не выполняется автоматически.
- Если есть `etc/config/network`, пользователь отдельно выбирает сохранить
  imported network или пройти текущий LAN/WAN wizard. В первом случае stale
  `etc/owrt-installer/interface-map`, `etc/uci-defaults/98-installer-network`
  и `etc/openwrt-installer-release` из backup удаляются, а новый network
  applier/map не создается. Во втором wizard-owned network применяется поверх
  imported config обычным first-boot path.
- Review показывает device, archive path, scope, compressed size, member count
  и полный SHA-256. Exact `ERASE /dev/...` остается единственным началом
  destructive flow.
- CLI `--config-backup FILE` использует тот же validator/RAM staging и нужен
  для automation; он не ослабляет archive policy. Test mode подменяет только
  enumerate/mount boundaries, а не validation или extraction.

Acceptance matrix:

- clean/import/back navigation во всех UI backends;
- read-only USB discovery, несколько partitions и несколько archives;
- valid config-only/full restore и imported-network/wizard-network branches;
- corrupt/truncated gzip, traversal/absolute/newline names, links/hardlinks,
  device/FIFO/socket, setuid/setgid, size/member-count bombs и low-memory gate;
- cleanup mount/workspace/staging при Cancel, validation failure, INT/TERM/HUP
  и post-copy failure;
- review provenance/hash и installed release metadata;
- QEMU install+boot с synthetic USB backup, проверкой imported UCI values и
  доказательством отсутствия stale installer network map/applier.

Итоговая проверка: deterministic source matrix прошла после post-extract
path/type/count/size audit. Исправлена утечка process-wide `umask 077` из
netinstall workspace; import больше не переносит metadata synthetic staging
root в установленный `/`, а `/etc` нормализуется до `0755`. Полный
`make iso-smoke` job `27a90c6a290645c4ab277ed50a21fabe` за 613 секунд прошел
BIOS, UEFI, local-disk BIOS/UEFI, missing-disk, hardware menu, VGA, clean
install+boot и USB config-import+install+boot. Post-import guest boot отдельно
подтвердил доступные режимы `/` и `/etc`. Checksum manifest проходит, а
`owrt-install`, UI, config-import helper и manifest внутри initramfs совпадают
с текущими source artifacts.

## Риски

- Escape-последовательности могут выглядеть плохо на serial или dumb terminals.
- UTF-8 рамки могут ломаться на VGA console.
- Local VGA mouse прошел QEMU и VMware, но до physical x86 gate остается experimental и disabled by default.
- Raw mode при аварии может оставить терминал без echo.
- `whiptail` увеличивает installer image на newt/slang dependencies; это принято ради понятного local-console UX.
- `dialog` потребует отдельной зависимости, если появится в feed или будет собираться отдельно.
- Progress percent для gzip payload требует точного uncompressed size и `pv`; иначе остается stage-only progress.

## Решения На Сейчас

- v1 использует обязательный `whiptail` на локальной console, сохраняя pure-shell ANSI и line fallback.
- ASCII рамки сделать default.
- Native SGR mouse использовать как lightweight дополнение к keyboard-first ANSI; `dialog` остается optional backend.
- Native local mouse через stock `mousedev` + hardened GPM держать за explicit feature flag до physical x86 проверки.
- Plan хранить в этом файле и зарегистрировать в Project Memory.

## Первые Реальные Задачи

1. [done] Добавить `owrt-installer-ui` с line backend и подключить его к `owrt-install`.
2. [done] Перевести `render_arrow_menu` на новый `ui_menu`.
3. [done] Добавить Hellforge header/footer/frame для меню, review, confirmation и install-stage экранов.
4. [done] Прогнать syntax-check, shellcheck и smoke.
5. [done] Прогнать QEMU BIOS/UEFI smoke на ISO после следующей сборки.
6. [done] После стабилизации глубже перевести network wizard forms.
7. [done] Только после этого заниматься `dialog --mouse`.
8. [done] Добавить безопасный review-level Edit flow без риска случайного destructive continue.
9. [done] Реализовать install progress screen, `/tmp/owrt-installer.log`, failure screen и manifest `payload_uncompressed_size`.
10. [done] Добавить быстрый `make ui-smoke` для повторяемой проверки line/ANSI/dialog-fallback UI.
11. [done] Добавить автоматический `make iso-smoke` для BIOS/UEFI hybrid ISO boot markers.
12. [done] Добавить terminal-size smoke для `auto` mode: 80x25, 100x30 и слишком маленький 79x19.
13. [done] Добавить `make install-flow-smoke` для `--dry-run` и `--skip-network-wizard` без записи на диск.
14. [done] Добавить Ctrl+C cleanup smoke для ANSI menu: pseudo-TTY, interrupt byte, exit 130, cursor restore.
15. [done] Добавить быстрый `make smoke` aggregate без ISO/QEMU rebuild.
16. [done] Добавить bare Esc cancel для ANSI menu и smoke-test: pseudo-TTY, delayed Enter на cancel screen, без случайного выбора.
17. [done] Добавить ANSI snapshot smoke: render menu в pseudo-TTY, strip ANSI/CR, проверить header/steps/items/footer без escape-мусора.
18. [done] Добавить `menu_warning` и красную warning-секцию на выборе диска, покрытую ANSI snapshot smoke.
19. [done] Уточнить auto-mode threshold до `80x24` и добавить terminal-size smoke для `80x24`/`80x23`.
20. [done] Пересобрать актуальный локальный hybrid ISO после UI/runtime изменений и прогнать hash/initramfs/fdisk/xorriso/QEMU smoke checks.
21. [done] Подготовить `v1.0-alpha.3` как отдельный alpha release tag, не двигая старые alpha tags.
22. [done] Добавить GitHub Actions `make smoke` gate на push/PR: workflow опубликован в `main`, OAuth-токен получил минимально необходимый `workflow` scope, а первый push run `31657834111` для commit `9e63814` прошел без `SKIP` за 43 секунды.
23. [deferred] Проверить настоящий `dialog --mouse` внутри live image после появления пакета: официальный OpenWrt `25.12.5` feed по-прежнему не предоставляет `dialog`; отдельный дублирующий artifact не добавлять, пока GPM-enabled `whiptail` закрывает local-console mouse path.
24. [done] Добавить native SGR mouse в ANSI menus для SSH/xterm-compatible terminals: click selection, wheel navigation, `OWRT_UI_NO_MOUSE=1`, terminal gating, cleanup и pseudo-TTY smoke.
25. [done] Исправить POSIX shell variable collision в `ui_repeat`, из-за которой render обнулял menu item count; добавить отдельный pseudo-TTY regression smoke для Down + Enter.
26. [done] Собрать и проверить `v1.0-alpha.4` ISO с native ANSI mouse: checksums, source/initramfs compare, GPT/El Torito, BIOS и UEFI QEMU smoke; публиковать отдельным tag.
27. [done] Реализовать настоящий form-level Back: ANSI `Esc`, dialog Cancel, line `!back`, WAN/WAN6 Back items, per-field PPPoE/static state machine, сохранение введенных значений и очистка ghost credentials; покрыть raw editor, secret, state и end-to-end line smoke.
28. [done] Собрать и проверить `v1.0-alpha.5` ISO с form-level Back: checksums, source/initramfs compare, GPT/El Torito, BIOS и UEFI QEMU smoke; опубликовать отдельным alpha tag без перемещения старых tags.
29. [done] Добавить официальный `whiptail` package, общую dialog/whiptail curses-абстракцию без `eval`, Hellforge newt theme, compact disk menu и real pseudo-TTY regression tests.
30. [done] Добавить VGA framebuffer smoke с backend/ready markers, собрать и проверить `v1.0-alpha.6` в BIOS/UEFI/VGA и опубликовать отдельным immutable alpha tag.
31. [done] Добавить обязательный `pv`, determinate payload write progress через отдельные data/progress FIFOs, native curses gauge, ANSI/line fallback и независимую проверку exit status `gzip`/`pv`/`dd`.
32. [done] Добавить regression tests для progress stream, failure/interrupt cleanup и выполнить реальную QEMU-установку на одноразовый qcow2 с проверкой progress markers и загрузки установленной системы.
33. [done] Собрать, проверить и опубликовать `v1.0-alpha.7` отдельным immutable prerelease с обновленными docs/checksums.
34. [done] Исследовать local VGA mouse как отдельный helper/package этап: input stack, threat model и архитектура без shell parser/TIOCSTI/uinput зафиксированы.
35. [done] Добавить pinned OpenWrt SDK-сборку GPM-enabled `libnewt`/`whiptail` и hardened daemon-only `gpm-daemon`; включить input/HID modules и `coreutils-stat` только в installer profile.
36. [done] Добавить QEMU acceptance: `/dev/input/event*`, PS/2 и USB relative mouse, rejection USB absolute-only tablet, click selection, daemon crash, exact-confirmation shutdown, cleanup socket/process и полный keyboard fallback.
37. [pending] После QEMU gate проверить local mouse на физической x86 машине; до этого не публиковать ее как поддерживаемую функцию и не включать автоматический runtime path по умолчанию.
38. [done] Подготовить безопасный bare-metal acceptance path: отдельный GRUB hardware-test entry с forced dry-run, явные safe-mode screens, QEMU disk-immutability proof, privacy-safe `owrt-hardware-report` и `PHYSICAL_X86_MOUSE_TEST.md`.
39. [pending] Закрыть physical alpha gate одним успешным wired USB HID report; перед включением mouse path по умолчанию получить второй pass на другом platform/input-controller class.
40. [done] Сделать physical gate машинно проверяемым: report schema v2, безопасный enum подключения, итоговый `physical_flow_result`, file mode `0600` и host-side verifier, который принимает первый alpha gate только для полного wired USB HID pass.
41. [done] До physical run зафиксировать точную `v1.0-alpha.8` release-candidate версию, пересобрать ISO и считать gate действительным только для этого неизмененного SHA-256; любое runtime-изменение требует новой сборки и повторного physical pass.
42. [done] Добавить единый pre-release gate: tracked candidate metadata, full runtime commit, ISO/manifest SHA-256, manifest version, runtime-diff guard и обязательный wired USB physical report verifier.
43. [superseded] Direct-evdev `EV_ABS` decoder и VMMouse twin routing прошли промежуточный QEMU gate, но были удалены после VMware diagnosis в пользу штатного kernel multiplexer.
44. [done] Реализовать boot entry `Download latest OpenWrt x86 image and install` по Online Combined Image Install design: signed official stable metadata, BIOS/UEFI combined image selection, RAM capacity gate, verified local payload и reuse существующего destructive confirmation/write flow.
45. [done] Заменить project-owned REL/ABS/VMMouse routing на stock Linux `mousedev` `/dev/input/mice`, GPM `imps2` и стандартный Newt console pointer; пройти полный QEMU mouse matrix и ручной VMware retest.
46. [done] Добавить payload-source abstraction и pinned official OpenWrt usign key без ослабления embedded payload verification.
47. [done] Добавить recoverable online network bootstrap: automatic DHCP по умолчанию, затем ручные DHCP/static IPv4/PPPoE и offline fallback.
48. [done] Добавить RAM/download/signature/checksum/gzip/layout verification до target selection и disk write.
49. [done] Интегрировать online metadata в review, installed release metadata и общий write/resize/config path.
50. [done] Добавить deterministic online-install smoke matrix и реальный QEMU network install+boot gate.
51. [done] Зафиксировать build `umask 022`, добавить regression smoke и повторно пройти полный embedded и online QEMU gates после сборки через `longrun` с исходной `umask 077`.
52. [done] Обновить embedded build, ImageBuilder/SDK pins и kernel package до OpenWrt `25.12.5`; исключить принятие неполного ImageBuilder directory и проверять version marker target payload.
53. [done] Добавить GRUB-пункт загрузки установленного OpenWrt, исправить UEFI early config на `(cd0)` и пройти BIOS/UEFI/missing-disk QEMU acceptance.
54. [done] Разделить PPPoE username/password для embedded и online flows, сохранить Back/retained state и исправить высоту `whiptail --passwordbox`; подтвердить экран на VMware через VNC без disk write.
55. [done] Добавить Phase 7 USB config-import architecture и threat model в основной план.
56. [done] Реализовать read-only USB enumerate/mount, archive picker, RAM-copy и cleanup lifecycle.
57. [done] Реализовать strict tar validator, config-only/full staging и resource limits.
58. [done] Встроить clean/import/network choices, review provenance и CLI/test seams.
59. [done] Применять staging после image write, защищать installer-owned metadata и imported network от stale first-boot applier.
60. [done] Добавить deterministic config-import smoke matrix без block-device privileges.
61. [done] Добавить QEMU USB backup install/boot acceptance, пересобрать ISO и обновить SHA/docs.
62. [done] Перезагрузить VMware test VM через VNC после финальной сборки `62653cac...` и подтвердить новый boot cycle, autostart и безопасный экран выбора `/dev/sda` без начала установки.
63. [done] Зафиксировать выбранный `v1.0-alpha.9` post-import runtime в immutable candidate commit `8e8593c5891ff69f98a9ee3ef5fcdd23444d2b51` и metadata `release/v1.0-alpha.9-candidate.env`, пересобрать ISO `2b570a2e...` из clean commit и повторить `make smoke`, `make mouse-qemu-smoke`, focused config-import и полный `make iso-smoke`; любое последующее runtime-изменение аннулирует candidate.
64. [pending] После успешного wired USB HID report выполнить `make release-gate`, опубликовать следующий immutable alpha tag/assets и не перемещать старые tags; включение mouse path по умолчанию оставить до второго platform/input-controller pass из задачи 39.
65. [done] Harden candidate freeze/gate: убрать shell `source` и historical default, требовать явный committed metadata path, ловить tracked/staged/untracked/unexpected-ignored runtime, встроить `build_commit`/`build_dirty` manifest в корень ISO и проверять его byte-for-byte; покрыть isolated Git smoke и повторить полный QEMU gate.
66. [done] Свести GRUB к трем пунктам, включить keyboard+mouse в unified installer, автоматически проверять strictly newer stable с embedded fallback и делать local-disk entry условным default; полный QEMU gate повторен до freeze.
67. [done] Устранить post-import boot hang из-за утечки `umask 077` и переноса staging-root metadata; добавить source и QEMU regression checks режимов `/`/`/etc` и installed boot.
68. [done] Сделать USB-relative QEMU mouse acceptance детерминированным: отдельные малые reports ниже GPM acceleration threshold, попадание в активную строку `OK`, USB/PS2 isolation, три повторных USB-прогона и полный mouse matrix.
69. [pending] Перезагрузить VMware test VM с frozen ISO `2b570a2e...`, подтвердить три GRUB entry, conditional local-disk default и безопасный autostart installer без disk write.
