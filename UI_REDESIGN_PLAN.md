# OpenWrt Hellforge Installer UI Plan

Дата: 2026-08-12.

Цель: сделать shell installer менее скучным, но не превратить его в тяжелый live-дистрибутив. Визуальное направление: темная консоль, жесткие ASCII-рамки, красно-янтарные warning-секции, аккуратные progress bars в духе DOS-инсталлеров и понятная логика уровня IPFire. Doom-брендинг, названия, графика и ассеты не использовать.

## Короткий вывод

Рекомендуемый путь: сначала сделать zero-dependency TUI на ANSI/POSIX shell поверх текущего `owrt-install`, затем отдельно добавить optional `dialog` backend для мыши там, где терминал реально передает mouse events.

Mouse support не должен быть базовым требованием первой версии. В локальной Linux console `tty1` мышь обычно не работает как terminal event без `gpm` или прямой обработки `/dev/input/event*`. В SSH/xterm-подобных терминалах и иногда в serial frontend `dialog --mouse` или SGR mouse reporting может работать. Поэтому базовая UX-модель должна оставаться keyboard-first.

## Принципы

- Безопасность важнее красоты: destructive flow, `ERASE /dev/...`, проверка payload SHA-256 и disk guards не ослаблять.
- Non-interactive CLI должен остаться стабильным: `--target`, `--lan-mac`, `--wan-mac`, `--lan-ip`, `--skip-network-wizard`, `--yes-i-know-this-will-erase-data`.
- Serial/pipe fallback обязателен: если нет нормальной TTY, остаются простые numbered prompts.
- Не добавлять тяжелые зависимости в v1. `dialog` уже есть в `profiles/optional-packages.txt`, но его использовать как optional backend, а не как единственный UI.
- ASCII default. UTF-8 box drawing можно добавить позже как опцию, но не делать базой из-за VGA/serial/font рисков.
- Все raw terminal modes должны восстанавливаться через `trap`: cursor visible, mouse off, `stty` restored.

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
| OPENWRT HELLFORGE INSTALLER                                      v1.0-alpha.1 |
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
      +-- ansi backend       default interactive TUI, no extra packages
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
OWRT_UI_MODE=auto|line|ansi|dialog
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

## Фаза 4: Optional Dialog Backend И Мышь

Цель: добавить mouse-friendly backend без зависимости от него.

Работы:

- Если `OWRT_UI_MODE=dialog` или `OWRT_UI_MODE=auto` и `dialog` доступен:
  - генерировать `/tmp/owrt-installer.dialogrc`;
  - выставлять `DIALOGRC`;
  - использовать `dialog --menu`, `--radiolist`, `--inputbox`, `--passwordbox`, `--yesno`, `--gauge`;
  - включать `--mouse`, если не задан `OWRT_UI_NO_MOUSE=1`.
- Если `dialog` не работает или terminal неподходящий, fallback на `ansi`.
- Для локальной VGA console мышь считать experimental: проверить отдельно, не обещать как гарантированную функцию.

Ограничение:

- `dialog --mouse` обычно работает там, где терминал передает mouse events. Обычная Linux console `tty1` часто этого не делает.
- Для настоящей мыши на VGA потребуется `gpm` или прямой evdev parser. Это отдельная фаза и отдельный риск.

Критерии приемки:

- Keyboard flow работает всегда.
- Mouse click работает хотя бы в SSH/xterm-подобном терминале при `dialog`.
- При отсутствии мыши UI не деградирует.

## Фаза 5: QEMU И Regression Tests

Цель: не выпускать красивый, но хрупкий installer.

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

Дополнительно:

- ANSI snapshot test: рендер меню в temp TTY или captured output, затем strip ANSI и проверка ключевых строк.
- Проверка terminal size: 80x25, 100x30, слишком узкий экран.
- Проверка dialog backend только если package реально есть в live image.

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

## Риски

- Escape-последовательности могут выглядеть плохо на serial или dumb terminals.
- UTF-8 рамки могут ломаться на VGA console.
- Mouse support может работать в SSH, но не работать на локальном экране.
- Raw mode при аварии может оставить терминал без echo.
- `dialog` увеличит installer image и может потянуть ncurses-зависимости.
- Progress percent для gzip payload требует точного uncompressed size; иначе будет только spinner/stage progress.

## Решения На Сейчас

- v1 делать на pure shell ANSI, без обязательного `dialog`.
- ASCII рамки сделать default.
- `dialog` и mouse support планировать как v2 после рабочей keyboard-first версии.
- Native local mouse через `gpm`/evdev не делать до отдельной проверки в QEMU и на железе.
- Plan хранить в этом файле и зарегистрировать в Project Memory.

## Первые Реальные Задачи

1. Добавить `owrt-installer-ui` с line backend и подключить его к `owrt-install`.
2. Перевести `render_arrow_menu` на новый `ui_menu`.
3. Добавить Hellforge header/footer/frame для disk selection.
4. Прогнать shellcheck/syntax-check.
5. Прогнать QEMU BIOS/UEFI smoke на одном экране.
6. После стабилизации перевести network wizard.
7. Только после этого заниматься `dialog --mouse`.
