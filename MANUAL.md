# lunafast-fw-upload — памятка

## Зависимости

- **adb** (Platform Tools).
- Для меню со **стрелками** и **галочками** (checklist): **`apt install dialog`**.

## Главное меню

**С `dialog`:** разделы открываются курсором. Раздел **«Прошивка»**:

1. Мастер (connect → APK/XAPK → выбор → установка)  
2. Подключить IP:PORT  
3. **Выбор устройств** (Пробел) → список сохраняется  
4. Показать сохранённые serial  
5. Установить APK/XAPK на сохранённый список  
6. Запуск приложения на сохранённом списке  
7. HTTP API операции: КриптоПро / screensaver / click-area / light  
8. **Сделать launcher** — отключить штатный launcher, назначить HOME (`ai.visionlabs.transactionapp`, `ai.visionlabs.lunafast2nextgen` или свой package)  
0. Назад  

**Без `dialog`:** те же номера в текстовых рамках.

Файл выбранных устройств: **`~/.lunafast_fw_upload/selected_targets`** (по одному serial в строке).

## Быстрый batch

```bash
./tablet_deploy.sh --no-ui
./tablet_deploy.sh --connect 192.168.1.211:5555 /путь/app.apk
```

## Настройки

Файл **`~/.lunafast_fw_upload/settings`** или **`LUNAFAST_CONFIG`**:

```
ADB_PORT=5555
SCAN_SUBNET=192.168.1
LIGHT_LEVEL=50
```
