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
  -m, --menu              — только меню
  --no-ui                 — adb connect, затем adb devices -l
  --connect IP:PORT       — явный adb connect (можно несколько раз); с --no-ui
                            вместо хостов по умолчанию; с .apk — подключить,
                            затем установить
  путь к .apk             — установка на все device (после --connect, если есть)
  -h, --help              — эта справка

По умолчанию при --no-ui: connect к ${DEFAULT_HOST1} и ${DEFAULT_HOST2}.

Настройки: LUNAFAST_CONFIG или ~/.lunafast_fw_upload/settings"
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

# Записать список serial в файл (по одному в строке)
refresh_serials_file() {
	sf=$1
	adb_device_serials >"$sf"
}

# Пронумерованный список из файла
print_numbered_serials() {
	sf=$1
	i=1
	while read -r line; do
		[ -z "$line" ] && continue
		printf '  %s) %s\n' "$i" "$line"
		i=$((i + 1))
	done <"$sf"
}

# Заметный заголовок шага выбора целей
banner_pick_devices() {
	printf '%s\n' ""
	printf '%s\n' "  >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
	printf '%s\n' "  >>>  ВЫБОР УСТРОЙСТВ ДЛЯ ПРОШИВКИ (по номерам)  <<<"
	printf '%s\n' "  >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
	printf '%s\n' "  Ниже — нумерованный список (только «device»):"
	printf '%s\n' ""
}

# choice: пусто / all / * / все → все строки из sf; иначе номера через пробел или запятую
# Результат в outf (по одному serial на строку, уникальные)
pick_serials_to_file() {
	sf=$1
	choice=$2
	outf=$3
	n=$(wc -l <"$sf" | tr -d ' ')
	: >"$outf"
	[ "${n:-0}" -eq 0 ] && return 1

	set_all=0
	ch=$(printf '%s' "$choice" | tr -d ' \t')
	[ -z "$ch" ] && set_all=1
	[ "$ch" = '*' ] && set_all=1
	case "$choice" in
	all | ALL | все | Все) set_all=1 ;;
	esac

	if [ "$set_all" -eq 1 ]; then
		cp "$sf" "$outf"
		return 0
	fi

	tmp=$(mktemp) || return 1
	nums=$(printf '%s' "$choice" | tr ',' ' ')
	for idx in $nums; do
		[ -z "$idx" ] && continue
		case "$idx" in
		*[!0-9]*)
			printf '%s\n' "Неверный номер: $idx (ожидаются 1–$n)" >&2
			rm -f "$tmp"
			return 1
			;;
		esac
		[ "$idx" -lt 1 ] || [ "$idx" -gt "$n" ] && {
			printf '%s\n' "Номер вне диапазона: $idx (1–$n)" >&2
			rm -f "$tmp"
			return 1
		}
		sed -n "${idx}p" "$sf" >>"$tmp"
	done
	sort -u "$tmp" >"$outf"
	rm -f "$tmp"
	[ -s "$outf" ] || return 1
	return 0
}

connect_pair() {
	p="$1"
	printf '%s ' "→ $DEFAULT_HOST1:$p ..."
	adb connect "${DEFAULT_HOST1}:${p}" 2>/dev/null || printf '%s' "ошибка "
	printf '%s ' "→ $DEFAULT_HOST2:$p ..."
	adb connect "${DEFAULT_HOST2}:${p}" 2>/dev/null || printf '%s' "ошибка "
	printf '\n'
}

# Проверка «что-то:порт» (IPv4:port или имя:port)
is_adb_target() {
	case "$1" in
	*:*:*) return 0 ;; # возможно IPv6 — пусть adb сам разберётся
	*:*)
		hostpart=${1%%:*}
		portpart=${1#*:}
		[ -n "$hostpart" ] && [ -n "$portpart" ] || return 1
		return 0
		;;
	*) return 1 ;;
	esac
}

connect_explicit_list() {
	for a in $CONNECT_LIST; do
		printf '%s\n' "→ adb connect $a"
		adb connect "$a" || printf '%s\n' "   ошибка" >&2
	done
}

quick_batch() {
	load_settings
	ensure_adb
	if [ -n "$CONNECT_LIST" ]; then
		printf '%s\n' "--- Подключение (--connect) ---"
		connect_explicit_list
	else
		printf '%s\n' "--- Подключение (порт $ADB_PORT, хосты по умолчанию) ---"
		connect_pair "$ADB_PORT"
	fi
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
	repeat_search=1
	while [ "$repeat_search" -eq 1 ]; do
		repeat_search=0
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

		post_search=1
		while [ "$post_search" -eq 1 ]; do
			printf '%s\n' ""
			printf '%s\n' "--- Устройства (adb devices -l) ---"
			adb devices -l
			printf '%s\n' "----------------------------------------------"
			printf '%s\n' "  1) Установить APK (выбор номеров устройств — см. шаг 2 в мастере)"
			printf '%s\n' "  2) Повторить поиск в этой подсети"
			printf '%s\n' "  0) Главное меню"
			printf '%s\n' "----------------------------------------------"
			printf '%s' "Дальше [0-2]: "
			read -r subc || return 0
			case "$subc" in
			1)
				menu_install --skip-connect
				;;
			2)
				repeat_search=1
				post_search=0
				;;
			0)
				post_search=0
				;;
			*)
				printf '%s\n' "Неверный ввод."
				;;
			esac
		done
	done
}

menu_install() {
	skipc=
	if [ "$1" = "--skip-connect" ]; then
		skipc=1
		shift
	fi
	load_settings
	ensure_adb
	printf '%s\n' "=================================================="
	printf '%s\n' "  УСТАНОВКА APK — сначала файл, потом КТО из списка"
	printf '%s\n' "=================================================="
	if [ -z "$skipc" ]; then
		printf '%s' "Шаг 0. ADB IP:PORT [Enter если уже подключено]: "
		read -r addr_line
		if [ -n "$addr_line" ]; then
			if is_adb_target "$addr_line"; then
				printf '%s\n' "→ adb connect $addr_line"
				adb connect "$addr_line" || printf '%s\n' "предупреждение: connect не удался" >&2
			else
				printf '%s\n' "Нужен формат IP:PORT (например 192.168.1.211:5555)" >&2
				read -r _
				return 1
			fi
		fi
	fi
	sf=$(mktemp) || exit 1
	picked=$(mktemp) || {
		rm -f "$sf"
		exit 1
	}
	refresh_serials_file "$sf"
	if [ ! -s "$sf" ]; then
		printf '%s\n' "Нет устройств «device». Укажите IP:PORT выше или п.1 (поиск)."
		rm -f "$sf" "$picked"
		read -r _
		return
	fi
	printf '%s\n' ""
	printf '%s' "Шаг 1. Путь к APK или имя из ./apks: "
	read -r path_in
	if [ -z "$path_in" ]; then
		rm -f "$sf" "$picked"
		read -r _
		return
	fi
	apk=$path_in
	if [ ! -f "$apk" ] && [ -f "apks/$path_in" ]; then
		apk="apks/$path_in"
	fi
	if [ ! -f "$apk" ]; then
		printf '%s\n' "Файл не найден: $path_in" >&2
		rm -f "$sf" "$picked"
		read -r _
		return
	fi
	banner_pick_devices
	print_numbered_serials "$sf"
	printf '%s\n' "  --------------------------------------------------"
	printf '%s\n' "  Шаг 2. КУДА ставим $(basename "$apk")?"
	printf '%s\n' "    Enter или «все» = на ВСЕ перечисленные"
	printf '%s\n' "    Или номера: одно (1) или несколько через пробел/запятую (1 3  или  1,2)"
	printf '%s\n' "  --------------------------------------------------"
	printf '%s' "  Ваш выбор номеров: "
	read -r pick_in
	if ! pick_serials_to_file "$sf" "$pick_in" "$picked"; then
		rm -f "$sf" "$picked"
		read -r _
		return 1
	fi
	tlist=$(tr '\n' ' ' <"$picked")
	printf '%s\n' ""
	printf '%s' "Подтвердить: $(basename "$apk") → устройства: $tlist ? [y/N]: "
	read -r y
	case "$y" in
	y | Y | yes | YES | д | Д | да | Да) ;;
	*)
		rm -f "$sf" "$picked"
		read -r _
		return
		;;
	esac
	while read -r serial; do
		[ -z "$serial" ] && continue
		printf '%s\n' ">>> $serial"
		adb -s "$serial" install -r "$apk" || printf '%s\n' "  ошибка" >&2
	done <"$picked"
	rm -f "$sf" "$picked"
	printf '%s\n' "Готово. Enter..."
	read -r _
}

main_menu() {
	ensure_adb
	if [ -n "$CONNECT_LIST" ]; then
		printf '%s\n' "--- Старт: adb connect (--connect) ---"
		connect_explicit_list
	fi
	while :; do
		load_settings
		printf '\n'
		printf '%s\n' "--- Уже подключённые устройства (adb devices -l) ---"
		adb devices -l
		printf '%s\n' "=============================================="
		printf '%s\n' "  lunafast-fw-upload"
		printf '%s\n' "  Порт $ADB_PORT   Подсеть ${SCAN_SUBNET}.x"
		printf '%s\n' "=============================================="
		printf '%s\n' "  1) Поиск устройств в сети"
		printf '%s\n' "  2) Установка APK — выбор устройств по номерам, затем файл"
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
	if [ -n "$CONNECT_LIST" ]; then
		printf '%s\n' "--- adb connect (--connect) ---"
		connect_explicit_list
	fi
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
CONNECT_LIST=

while [ $# -gt 0 ]; do
	case "$1" in
	--connect)
		shift
		if [ -z "$1" ]; then
			printf '%s\n' "Ожидается IP:PORT после --connect" >&2
			exit 1
		fi
		if ! is_adb_target "$1"; then
			printf '%s\n' "Неверный адрес (нужно IP:PORT или host:PORT): $1" >&2
			exit 1
		fi
		CONNECT_LIST="$CONNECT_LIST${CONNECT_LIST:+ }$1"
		shift
		;;
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
