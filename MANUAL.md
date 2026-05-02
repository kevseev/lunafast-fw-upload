# Ручное руководство — lunafast-fw-upload (Docker)

Документ для установки **из релиза GitHub** без клонирования репозитория. В релизе обычно лежат:

| Файл | Назначение |
|------|------------|
| `lunafast-tablet-deploy-vVERSION.tar.gz` | Полный образ Docker (`docker save`), сжатый gzip |
| `docker-compose.yml` | Запуск контейнера без сборки (`image: …`) |
| `MANUAL.md` | Эта инструкция |

Версия в имени архива и в теге образа в `docker-compose.yml` должны совпадать (например `v1.0.1`).

## Требования

- **Docker** и **Docker Compose** (Plugin v2: `docker compose`).
- **Linux** на машине, где запускаете Compose: в файле используется `network_mode: host`, чтобы контейнер видел планшеты в LAN (`192.168.x.x`) так же, как хост.
- Планшеты с **сетевым ADB** (по умолчанию в скрипте: `192.168.1.211:5555` и `192.168.1.213:5555`).

## 1. Загрузка образа из архива

Скачайте **`lunafast-tablet-deploy-vVERSION.tar.gz`** со страницы [Releases](https://github.com/kevseev/lunafast-fw-upload/releases).

```bash
gzip -dc lunafast-tablet-deploy-v1.0.1.tar.gz | docker load
```

Либо:

```bash
gunzip -c lunafast-tablet-deploy-v1.0.1.tar.gz | docker load
```

Проверка:

```bash
docker images | grep lunafast-tablet-deploy
```

Должен появиться тег **`v1.0.1`** (или тот, что указан в релизе).

## 2. Подготовка каталога

Создайте рабочую папку и положите рядом:

- скачанный **`docker-compose.yml`** из того же релиза;
- каталог **`apks/`** с файлами `.apk` (можно пустым, если только просматриваете устройства).

Пример:

```text
~/lunafast-fw/
├── docker-compose.yml
└── apks/
    └── my-app.apk
```

## 3. Запуск

Интерактивный экран (псевдографика), затем выход контейнера после окончания скрипта:

```bash
cd ~/lunafast-fw
docker compose up
```

Однократный прогон сразу с установкой APK (путь **внутри контейнера** — `/apks/...`):

```bash
docker compose run --rm tablet-deploy /apks/my-app.apk
```

Фильтр по подстроке модели/производителя:

```bash
docker compose run --rm tablet-deploy --model P3000 /apks/my-app.apk
```

Плоский вывод без большого макета:

```bash
docker compose run --rm tablet-deploy --no-ui
docker compose run --rm tablet-deploy --no-ui /apks/my-app.apk
```

Свои хосты ADB:

```bash
docker compose run --rm tablet-deploy --host 192.168.1.100:5555 --host 192.168.1.101:5555 --no-ui
```

## 4. Несовпадение тега образа

Если в `docker-compose.yml` указан тег **`lunafast-tablet-deploy:v1.0.1`**, а после `docker load` видите другой тег — переименуйте:

```bash
docker tag lunafast-tablet-deploy:старый_тег lunafast-tablet-deploy:v1.0.1
```

Или отредактируйте строку `image:` в `docker-compose.yml` под фактический тег.

## 5. Частые проблемы

- **`network_mode: host` недоступен** — типично не для Linux; на Windows/macOS используйте запуск Python/`adb` на хосте или иной сетевой режим по согласованию с администратором.
- **Устройства не видны** — проверьте `adb connect` с хоста, файрвол, что на планшете включена отладка по сети и порт **5555** (или укажите свой `--host`).
- **`no such file` для APK** — файл должен быть в `./apks/` на хосте и путь в контейнере начинаться с `/apks/`.

## Исходный код и разработка

Репозиторий: [github.com/kevseev/lunafast-fw-upload](https://github.com/kevseev/lunafast-fw-upload). Сборка образа из исходников описана в `README.md`.
