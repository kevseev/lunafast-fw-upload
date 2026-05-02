# lunafast-fw-upload

Консольное **shell**-приложение (`/bin/sh`): **поиск** устройств с сетевым ADB в LAN, **установка APK**, **настройка порта** и подсети сканирования.

По умолчанию для быстрого `adb connect` (режим `--no-ui`): **192.168.1.211** и **192.168.1.213**, порт из настроек (**5555**).

## Требования

- [Android Platform Tools](https://developer.android.com/tools/releases/platform-tools) — команда **`adb`** в `PATH`.
- Для быстрого пункта «Поиск» желателен **`nc`** (netcat); без него используется перебор `adb connect` по всей подсети (дольше).

## Запуск

```bash
chmod +x tablet_deploy.sh   # один раз
./tablet_deploy.sh          # меню (нужен интерактивный терминал)
./tablet_deploy.sh --menu
./tablet_deploy.sh --no-ui  # connect к .211 и .213, затем adb devices -l
./tablet_deploy.sh /путь/app.apk  # установка на все «device»
./tablet_deploy.sh --help
```

В меню: **1** — поиск в сети, **2** — установка APK (можно имя файла из `./apks/`), **3** — порт ADB и подсеть (например `192.168.1`).

## Настройки

Файл **`~/.lunafast_fw_upload/settings`** (формат `KEY=value`):

```
ADB_PORT=5555
SCAN_SUBNET=192.168.1
```

Или каталог/файл через **`LUNAFAST_CONFIG`** (как каталог — создаётся `settings` внутри).

## Структура

| Файл | Назначение |
|------|------------|
| `tablet_deploy.sh` | Скрипт |
| `MANUAL.md` | Краткая памятка |
| `apks/` | APK для п.2 меню (в git не коммитятся) |

## Лицензия

По усмотрению владельца репозитория.
