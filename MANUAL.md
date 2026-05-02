# lunafast-fw-upload — памятка

## Установка

1. Установите [Android Platform Tools](https://developer.android.com/tools/releases/platform-tools) и убедитесь, что **`adb`** доступен в терминале.
2. В каталоге проекта:

```bash
pip install -r requirements.txt
```

## Запуск

Интерактивное меню (поиск, установка APK, настройка порта и подсети):

```bash
python3 tablet_deploy.py
```

Пакетно, без меню:

```bash
python3 tablet_deploy.py --no-ui
python3 tablet_deploy.py --no-ui /полный/путь/к/файлу.apk
```

Настройки меню сохраняются в **`~/.lunafast_fw_upload/settings.json`**. Путь к файлу настроек можно задать переменной **`LUNAFAST_CONFIG`** (полный путь к JSON-файлу).

## Сеть

Планшеты должны быть доступны по IP с вашей машины; на устройстве должен быть включён **отладка по Wi‑Fi** / **Wireless debugging** на том же порту, что в настройках (по умолчанию **5555**).
