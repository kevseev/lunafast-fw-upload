# lunafast-fw-upload

Консольный **shell**-скрипт: поиск ADB в LAN, **выбор устройств** для прошивки, установка APK, настройки.

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
  - **п.2** — отдельный пункт **«Выбор устройств для прошивки»** (checklist → сохраняется в `~/.lunafast_fw_upload/selected_targets`);
  - **п.3** — установить APK **только на сохранённый список**;
  - **п.4** — мастер: connect → APK → checklist → установка.

## Запуск

```bash
chmod +x tablet_deploy.sh
./tablet_deploy.sh
./tablet_deploy.sh --no-ui
./tablet_deploy.sh --connect IP:5555 app.apk
```

Настройки: `~/.lunafast_fw_upload/settings` (`ADB_PORT`, `SCAN_SUBNET`), переменная **`LUNAFAST_CONFIG`**.

## Структура

| Файл | Назначение |
|------|------------|
| `tablet_deploy.sh` | Скрипт |
| `MANUAL.md` | Краткая памятка |
| `apks/` | APK (не в git) |

## Лицензия

По усмотрению владельца репозитория.
