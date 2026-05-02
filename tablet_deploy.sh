#!/bin/sh
# lunafast-fw-upload — консоль: поиск ADB в LAN, установка APK, настройка порта.
# Зависимости: adb в PATH; для п.1 желателен nc (netcat), иначе медленнее через adb connect.

set_defaults() {
	ADB_PORT=5555
	SCAN_SUBNET=192.168.1
}

# Адреса для быстрого подключения (--no-ui или не-TTY без аргументов)
DEFAULT_HOST1=192.168.1.211
DEFAULT_HOST2=192.168.1.213

settings_file() {
	if [ -n "$LUNAFAST_CONFIG" ]; then
		if [ -d "$LUNAFAST_CONFIG" ]; then
			printf '%s/settings\n' "$LUNAFAST_CONFIG"
		else
			printf '%s\n' "$LUNAFAST_CONFIG"
		fi
	else
		printf '%s/.lunafast_fw_upload/settings\n' "${HOME:-$PWD}"
	fi
}

load_settings() {
	set_defaults
	SETTINGS_FILE=$(settings_file)
	export SETTINGS_FILE
	if [ -f "$SETTINGS_FILE" ]; then
		# shellcheck source=/dev/null
		. "$SETTINGS_FILE"
	fi
	: "${ADB_PORT:=5555}"
	: "${SCAN_SUBNET:=192.168.1}"
}

save_settings() {
	dir=$(dirname "$SETTINGS_FILE")
	mkdir -p "$dir" || exit
	{
		printf 'ADB_PORT=%s\n' "$ADB_PORT"
		printf 'SCAN_SUBNET=%s\n' "$SCAN_SUBNET"
	} >"$SETTINGS_FILE" || exit
	printf 'Сохранено: %s\n' "$SETTINGS_FILE"
}

usage() {
	printf '%s\n' "Использование: tablet_deploy.sh [опции] [файл.apk]
  (без аргументов, TTY) — интерактивное меню
  -m, --menu          — только меню
  --no-ui             — adb connect к ${DEFAULT_HOST1} и ${DEFAULT_HOST2}, список устройств
  путь к .apk         — установка на все device
  -h, --help          — эта справка

Настройки: см. файл из LUNAFAST_CONFIG или ~/.lunafast_fw_upload/settings"
}

ensure_adb() {
	if ! command -v adb >/dev/null 2>&1; then
		printf '%s\n' "Ошибка: команда adb не найдена. Установите Android Platform Tools." >&2
		exit 1
	fi
}

probe_tcp() {
	if command -v nc >/dev/null 2>&1; then
		nc -z -w1 "$1" "$2" >/dev/null 2>&1
	else
		return 1
	fi
}

adb_device_serials() {
	adb devices 2>/dev/null | awk 'NR>1 && $2=="device" { print $1 }'
}

connect_pair() {
	p="$1"
	printf '%s ' "→ $DEFAULT_HOST1:$p ..."
	adb connect "${DEFAULT_HOST1}:${p}" 2>/dev/null || printf '%s' "ошибка "
	printf '%s ' "→ $DEFAULT_HOST2:$p ..."
	adb connect "${DEFAULT_HOST2}:${p}" 2>/dev/null || printf '%s' "ошибка "
	printf '\n'
}

quick_batch() {
	load_settings
	ensure_adb
	printf '%s\n' "--- Подключение (порт $ADB_PORT) ---"
	connect_pair "$ADB_PORT"
	printf '%s\n' "--- adb devices -l ---"
	adb devices -l
}

menu_settings() {
	load_settings
	printf '%s\n' "--- Текущие настройки ---"
	printf 'Порт ADB: %s\n' "$ADB_PORT"
	printf 'Подсеть поиска: %s.x (хосты .1–.254)\n' "$SCAN_SUBNET"
	printf '%s ' "Новый порт ADB [Enter = оставить]:"
	read -r newp
	if [ -n "$newp" ]; then
		ADB_PORT=$newp
	fi
	printf '%s ' "Подсеть, три октета (напр. 192.168.1) [Enter = оставить]:"
	read -r news
	if [ -n "$news" ]; then
		SCAN_SUBNET=$news
	fi
	ct=0
	o1= o2= o3=
	for o in $(printf '%s' "$SCAN_SUBNET" | tr '.' ' '); do
		ct=$((ct + 1))
		case $ct in 1) o1=$o ;; 2) o2=$o ;; 3) o3=$o ;; esac
	done
	if [ "$ct" -ne 3 ]; then
		printf '%s\n' "Ошибка: нужно три октета, например 192.168.1" >&2
		read -r _
		return 1
	fi
	case "$o1$o2$o3" in
	*[!0-9]*) printf '%s\n' "Ошибка: только цифры и точки в подсети" >&2; read -r _; return 1 ;;
	esac
	if ! printf '%s' "$ADB_PORT" | grep -q '^[0-9][0-9]*$' || [ "$ADB_PORT" -lt 1 ] || [ "$ADB_PORT" -gt 65535 ]; then
		printf '%s\n' "Ошибка: порт 1–65535" >&2
		read -r _
		return 1
	fi
	save_settings
	read -r _
}

menu_search() {
	load_settings
	ensure_adb
	sub=$(printf '%s' "$SCAN_SUBNET" | sed 's/\.$//')
	p="$ADB_PORT"
	printf '%s\n' "--- Поиск: ${sub}.1–254, TCP $p ---"
	found=$(mktemp) || exit 1
	trap 'rm -f "$found"' EXIT INT

	if command -v nc >/dev/null 2>&1; then
		i=1
		while [ "$i" -le 254 ]; do
			ip="${sub}.${i}"
			if probe_tcp "$ip" "$p"; then
				printf '%s\n' "$ip" >>"$found"
			fi
			i=$((i + 1))
		done
	else
		printf '%s\n' "(nc нет — перебор adb connect, может занять несколько минут)"
		i=1
		while [ "$i" -le 254 ]; do
			ip="${sub}.${i}"
			out=$(adb connect "${ip}:${p}" 2>&1) || true
			case "$out" in
			*connected* | *already*)
				printf '%s\n' "$ip" >>"$found"
				;;
			esac
			i=$((i + 1))
		done
	fi

	n=$(wc -l <"$found" | tr -d ' ')
	if [ "${n:-0}" -eq 0 ] || [ -z "$n" ]; then
		printf '%s\n' "Открытых портов / успешных connect не найдено."
	else
		printf '%s\n' "Кандидатов: $n. Подключение adb..."
		while read -r ip; do
			[ -z "$ip" ] && continue
			printf '%s\n' "  adb connect ${ip}:${p}"
			adb connect "${ip}:${p}" || true
		done <"$found"
	fi
	rm -f "$found"
	trap - EXIT INT

	printf '%s\n' ""
	printf '%s\n' "--- Устройства ---"
	adb devices -l
	read -r _
}

menu_install() {
	load_settings
	ensure_adb
	list=$(adb_device_serials)
	if [ -z "$list" ]; then
		printf '%s\n' "Нет устройств «device». Сначала п.1 (поиск)."
		read -r _
		return
	fi
	printf '%s\n' "Устройства:"
	printf '%s\n' "$list" | while read -r s; do printf '  %s\n' "$s"; done
	printf '%s\n' "---"
	printf '%s' "Путь к APK или имя из ./apks: "
	read -r path_in
	if [ -z "$path_in" ]; then
		read -r _
		return
	fi
	apk=$path_in
	if [ ! -f "$apk" ] && [ -f "apks/$path_in" ]; then
		apk="apks/$path_in"
	fi
	if [ ! -f "$apk" ]; then
		printf '%s\n' "Файл не найден: $path_in" >&2
		read -r _
		return
	fi
	printf '%s' "Установить $(basename "$apk") на все? [y/N]: "
	read -r y
	case "$y" in
	y | Y | yes | YES | д | Д | да | Да) ;;
	*) read -r _; return ;;
	esac
	for serial in $list; do
		printf '%s\n' ">>> $serial"
		adb -s "$serial" install -r "$apk" || printf '%s\n' "  ошибка" >&2
	done
	read -r _
}

main_menu() {
	while :; do
		load_settings
		clear 2>/dev/null || printf '\n\n'
		printf '%s\n' "=============================================="
		printf '%s\n' "  lunafast-fw-upload"
		printf '%s\n' "  Порт $ADB_PORT   Подсеть ${SCAN_SUBNET}.x"
		printf '%s\n' "=============================================="
		printf '%s\n' "  1) Поиск устройств в сети"
		printf '%s\n' "  2) Установка APK"
		printf '%s\n' "  3) Настройки (порт ADB, подсеть)"
		printf '%s\n' "  0) Выход"
		printf '%s\n' "=============================================="
		printf '%s' "Выбор [0-3]: "
		read -r c || exit 0
		case "$c" in
		1) menu_search ;;
		2) menu_install ;;
		3) menu_settings ;;
		0) printf '%s\n' "Выход."; exit 0 ;;
		*) printf '%s\n' "Неверный пункт. Enter..."; read -r _ ;;
		esac
	done
}

install_apk_batch() {
	apk=$1
	if [ ! -f "$apk" ]; then
		printf '%s\n' "Нет файла: $apk" >&2
		exit 1
	fi
	load_settings
	ensure_adb
	list=$(adb_device_serials)
	if [ -z "$list" ]; then
		printf '%s\n' "Нет устройств." >&2
		exit 1
	fi
	err=0
	for serial in $list; do
		printf '%s\n' ">>> $serial"
		adb -s "$serial" install -r "$apk" || err=1
	done
	exit "$err"
}

MENU=
NO_UI=
APK=

while [ $# -gt 0 ]; do
	case "$1" in
	-m | --menu)
		MENU=1
		shift
		;;
	--no-ui)
		NO_UI=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		break
		;;
	-*)
		printf '%s\n' "Неизвестно: $1" >&2
		usage >&2
		exit 1
		;;
	*)
		break
		;;
	esac
done

[ $# -gt 0 ] && APK=$1

if [ -n "$APK" ]; then
	install_apk_batch "$APK"
	exit $?
fi

if [ -n "$NO_UI" ]; then
	quick_batch
	exit 0
fi

if [ -n "$MENU" ] || { [ -z "$APK" ] && [ -t 0 ] && [ -t 1 ]; }; then
	if [ ! -t 0 ] || [ ! -t 1 ]; then
		printf '%s\n' "Нужен TTY для меню. Используйте tablet_deploy.sh --no-ui" >&2
		exit 1
	fi
	ensure_adb
	main_menu
	exit 0
fi

quick_batch
