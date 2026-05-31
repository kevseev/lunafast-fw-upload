# lunafast-fw-upload

Консольный **shell**-скрипт: поиск ADB в LAN, **выбор устройств** для прошивки, установка APK/XAPK, HTTP-операции по выбранным устройствам и настройки.

## Интерфейс

1. **С пакетом `dialog`** (рекомендуется): псевдографика **ncurses** — стрелки, **вложенные меню**, **checklist** (Пробел отмечает устройства), заголовки с иерархией `Главная › Прошивка › …`.

```bash
sudo apt install dialog   # Debian/Ubuntu
./tablet_deploy.sh
```

2. **Без `dialog`**: текстовые рамки Unicode и те же пункты по номерам (подсказка при запуске).

## Иерархия меню (dialog)

- **Главное меню** → Сеть / **Прошивка** / Настройки / просмотр `adb devices`.
- **Прошивка** (вложенное):
  - **п.3** — отдельный пункт **«Выбор устройств для операций»** (checklist → сохраняется в `~/.lunafast_fw_upload/selected_targets`);
  - **п.5** — установить APK/XAPK **только на сохранённый список**;
  - **п.7** — подпункт **HTTP API операции**:
    - КриптоПро (`PUT /cryptopro/upload/container`);
    - заставка (`POST /screensaver`);
    - кликабельная зона (`POST /click-area`);
    - подсветка (`POST /light`, payload `{"command":"on","light_level":X}`);
  - **п.8** — **launcher**: `pm disable-user` штатных launcher → `cmd role` HOME для `ai.visionlabs.transactionapp`, `ai.visionlabs.lunafast2nextgen` или своего package;
  - **п.9** — **healthcheck** по сохранённому списку целей (`GET :HEALTH_PORT/HEALTH_PATH`).

После **Сеть › поиск** устройства записываются в `scanned_devices` и отключаются от adb; при **выборе целей** связь проверяется заново (без связи — не сохранить).

## Запуск

```bash
chmod +x tablet_deploy.sh
./tablet_deploy.sh
./tablet_deploy.sh --no-ui
./tablet_deploy.sh --connect IP:5555 app.apk
```

Настройки: `~/.lunafast_fw_upload/settings` (`ADB_PORT`, `SCAN_SUBNET`, `HEALTH_PORT`, `HEALTH_PATH`, `CLICK_X1..CLICK_Y2`, `LIGHT_LEVEL`), переменная **`LUNAFAST_CONFIG`**.

## Структура

| Файл | Назначение |
|------|------------|
| `tablet_deploy.sh` | Скрипт |
| `MANUAL.md` | Краткая памятка |
| `apks/` | APK (не в git) |

## Лицензия

По усмотрению владельца репозитория.
