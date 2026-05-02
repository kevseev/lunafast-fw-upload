# lunafast-fw-upload — памятка

## Установка

1. Установите **adb** (Android Platform Tools).
2. Сделайте скрипт исполняемым: `chmod +x tablet_deploy.sh`

## Меню

```bash
./tablet_deploy.sh
```

Пункты: поиск по LAN, установка APK, настройки порта и подсети.

## Без меню

```bash
./tablet_deploy.sh --no-ui
./tablet_deploy.sh --connect 192.168.1.50:5555 --no-ui
./tablet_deploy.sh --connect 192.168.1.211:5555 /полный/путь/app.apk
./tablet_deploy.sh /полный/путь/app.apk
```

## Настройки

Файл по умолчанию: **`~/.lunafast_fw_upload/settings`**

Либо переменная **`LUNAFAST_CONFIG`**: путь к файлу настроек или к каталогу (тогда используется `<каталог>/settings`).

Формат файла — обычные присваивания для shell:

```
ADB_PORT=5555
SCAN_SUBNET=192.168.1
```

*(Ранее использовавшийся JSON из версии на Python сюда не подходит — перенастройте порт и подсеть вручную один раз.)*
