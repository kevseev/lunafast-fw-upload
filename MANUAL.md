# lunafast-fw-upload — памятка

## Зависимости

- **adb** (Platform Tools).
- Для меню со **стрелками** и **галочками** (checklist): **`apt install dialog`**.

## Главное меню

**С `dialog`:** разделы открываются курсором. Раздел **«Прошивка»**:

1. Подключить IP:PORT  
2. **Выбор устройств** (Пробел) → список сохраняется  
3. Установить APK на сохранённый список  
4. Мастер (всё подряд)  
5. Показать сохранённые serial  
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
```
