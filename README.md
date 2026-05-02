# lunafast-fw-upload

Консольный инструмент для **подключения к Android‑планшетам по сетевому ADB**, **просмотра модели/производителя** и **массовой установки APK**. Интерфейс в терминале оформлен через [Rich](https://github.com/Textualize/rich) (псевдографика: рамки, таблицы).

По умолчанию ожидаются два устройства в LAN:

| Хост            | Порт ADB |
|-----------------|----------|
| `192.168.1.211` | `5555`   |
| `192.168.1.213` | `5555`   |

Список хостов можно переопределить флагом `--host` (см. ниже).

## Требования

- **Android Platform Tools** (`adb` в `PATH`) — при запуске **не** из Docker.
- На планшетах: включена **отладка по сети** / **Wireless debugging**, порт **5555** (или свой порт — укажите в `IP:PORT`).
- Сеть: машина с инструментом должна доходить до IP планшетов.

## Быстрый старт (Python)

```bash
pip install -r requirements.txt
python3 tablet_deploy.py
```

Установка APK на все подключённые после `adb connect` устройства:

```bash
python3 tablet_deploy.py /path/to/app.apk
```

Только устройства, у которых производитель + модель содержат подстроку:

```bash
python3 tablet_deploy.py --model TabA /path/to/app.apk
```

Свои хосты:

```bash
python3 tablet_deploy.py --host 192.168.1.100:5555 --host 192.168.1.101:5559
```

Плоский вывод без большого макета:

```bash
python3 tablet_deploy.py --no-ui /path/to/app.apk
```

## Docker и Compose

Сборка и запуск из каталога репозитория:

```bash
docker compose build
```

Интерактивный экран (нужен TTY):

```bash
docker compose run --rm tablet-deploy
```

APK удобно класть в `./apks/` на хосте — каталог смонтирован в контейнер как `/apks` (только чтение):

```bash
docker compose run --rm tablet-deploy /apks/my-application.apk
```

На **Linux** в `docker-compose.yml` используется `network_mode: host`, чтобы контейнер видел планшеты в локальной сети так же, как хост.

Дополнительные аргументы скрипта передаются после имени сервиса:

```bash
docker compose run --rm tablet-deploy --no-ui --model Samsung /apks/app.apk
```

## Структура репозитория

| Файл / каталог   | Назначение                          |
|------------------|-------------------------------------|
| `tablet_deploy.py` | Основной скрипт                   |
| `requirements.txt` | Зависимости Python                |
| `Dockerfile`     | Образ с Python, `adb`, зависимостями |
| `docker-compose.yml` | Запуск с `./apks` и host-сетью |
| `apks/`          | Каталог для APK (не коммитятся бинарники) |

## Лицензия

По усмотрению владельца репозитория; при необходимости добавьте файл `LICENSE`.
