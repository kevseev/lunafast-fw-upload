#!/bin/sh
# lunafast-fw-upload — поиск ADB в LAN, прошивка APK, настройки.
# Интерфейс: при наличии пакета «dialog» — псевдографика, стрелки, вложенные меню.
# Иначе — текстовый режим с рамками (ASCII). Нужны: adb; для поиска желателен nc.

set_defaults() {
	ADB_PORT=5555
	SCAN_SUBNET=192.168.1
}

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

state_dir() {
	dirname "$(settings_file)"
}

selected_targets_file() {
	printf '%s/selected_targets\n' "$(state_dir)"
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
}

usage() {
	printf '%s\n' "Использование: tablet_deploy.sh [опции] [файл.apk]
  Интерфейс: dialog (меню со стрелками), если установлен пакет «dialog».
  -m, --menu      меню
  --no-ui         быстрый adb connect + devices
  --connect H:P   (повторимо) явный connect; с .apk — ставит на все device
  -h, --help

UI без dialog: текстовые рамки. Установка: apt install dialog (Debian/Ubuntu)."
}

ensure_adb() {
	command -v adb >/dev/null 2>&1 || {
		printf '%s\n' "Нет adb в PATH." >&2
		exit 1
	}
}

have_dialog() {
	command -v dialog >/dev/null 2>&1
}

probe_tcp() {
	command -v nc >/dev/null 2>&1 && nc -z -w1 "$1" "$2" >/dev/null 2>&1
}

adb_device_serials() {
	adb devices 2>/dev/null | awk 'NR>1 && $2=="device" { print $1 }'
}

refresh_serials_file() {
	adb_device_serials >"$1"
}

is_adb_target() {
	case "$1" in
	*:*:*) return 0 ;;
	*:*)
		h=${1%%:*}
		p=${1#*:}
		[ -n "$h" ] && [ -n "$p" ] || return 1
		return 0
		;;
	*) return 1 ;;
	esac
}

connect_pair() {
	p="$1"
	adb connect "${DEFAULT_HOST1}:${p}" 2>/dev/null
	adb connect "${DEFAULT_HOST2}:${p}" 2>/dev/null
}

connect_explicit_list() {
	for a in $CONNECT_LIST; do adb connect "$a" || true; done
}

quick_batch() {
	load_settings
	ensure_adb
	if [ -n "$CONNECT_LIST" ]; then
		connect_explicit_list
	else
		connect_pair "$ADB_PORT"
	fi
	adb devices -l
}

pick_serials_to_file() {
	sf=$1
	choice=$2
	outf=$3
	n=$(wc -l <"$sf" | tr -d ' ')
	: >"$outf"
	[ "${n:-0}" -eq 0 ] && return 1
	a=0
	ch=$(printf '%s' "$choice" | tr -d ' \t')
	[ -z "$ch" ] && a=1
	[ "$ch" = '*' ] && a=1
	case "$choice" in all | ALL | все | Все) a=1 ;; esac
	if [ "$a" -eq 1 ]; then
		cp "$sf" "$outf"
		return 0
	fi
	t=$(mktemp) || return 1
	for idx in $(printf '%s' "$choice" | tr ',' ' '); do
		[ -z "$idx" ] && continue
		case "$idx" in *[!0-9]*)
			rm -f "$t"
			return 1
			;;
		esac
		[ "$idx" -lt 1 ] || [ "$idx" -gt "$n" ] && {
			rm -f "$t"
			return 1
		}
		sed -n "${idx}p" "$sf" >>"$t"
	done
	sort -u "$t" >"$outf"
	rm -f "$t"
	[ -s "$outf" ] || return 1
}

# ─── Поиск (ядро) ───
run_scan_connect() {
	load_settings
	sub=$(printf '%s' "$SCAN_SUBNET" | sed 's/\.$//')
	p="$ADB_PORT"
	found=$(mktemp) || exit 1
	if command -v nc >/dev/null 2>&1; then
		i=1
		while [ "$i" -le 254 ]; do
			probe_tcp "${sub}.${i}" "$p" && printf '%s\n' "${sub}.${i}" >>"$found"
			i=$((i + 1))
		done
	else
		i=1
		while [ "$i" -le 254 ]; do
			ip="${sub}.${i}"
			o=$(adb connect "${ip}:${p}" 2>&1) || true
			case "$o" in *connected* | *already*) printf '%s\n' "$ip" >>"$found" ;; esac
			i=$((i + 1))
		done
	fi
	if [ -s "$found" ]; then
		while read -r ip; do
			[ -z "$ip" ] && continue
			adb connect "${ip}:${p}" || true
		done <"$found"
	fi
	rm -f "$found"
}

# ═══════════════ dialog UI ═══════════════
dialog_main() {
	ensure_adb
	[ -n "$CONNECT_LIST" ] && connect_explicit_list
	while true; do
		load_settings
		c=$(dialog --stdout --clear --colors \
			--title "[ lunafast-fw-upload ] ─ Главное меню" \
			--menu "Порт: $ADB_PORT  │  Подсеть: ${SCAN_SUBNET}.x\n\n↑↓ выбор, Enter — открыть раздел." 20 76 6 \
			1 "Сеть › поиск устройств (скан LAN)" \
			2 "Прошивка › вложенное меню (выбор целей, APK…)" \
			3 "Настройки" \
			4 "Просмотр: adb devices -l" \
			0 "Выход") || true
		ex=$?
		[ "$ex" -eq 255 ] || [ "$ex" -eq 1 ] && break
		case "$c" in
		1) dialog_search_flow ;;
		2) dialog_flash_menu ;;
		3) dialog_settings ;;
		4)
			_tf=$(mktemp)
			adb devices -l >"$_tf"
			dialog --title "[ устройства ]" --textbox "$_tf" 22 78
			rm -f "$_tf"
			;;
		0) break ;;
		esac
	done
}

dialog_search_flow() {
	while true; do
		load_settings
		dialog --title "[ Сеть › поиск ]" --infobox "Сканирование ${SCAN_SUBNET}.x …" 6 50
		run_scan_connect
		_tf=$(mktemp)
		adb devices -l >"$_tf"
		dialog --title "[ Сеть › результат ]" --textbox "$_tf" 22 78
		rm -f "$_tf"
		a=$(dialog --stdout --title "[ Сеть › дальше ]" --menu "Действие после поиска:" 16 72 4 \
			1 "Прошивка › установить APK (мастер)" \
			2 "Повторить поиск" \
			0 "◀ Назад в главное меню") || break
		case "$a" in
		1) dialog_install_wizard ;;
		2) ;; # снова цикл — повторный скан
		0) break ;;
		esac
	done
}

dialog_flash_menu() {
	while true; do
		b=$(dialog --stdout --clear \
			--title "[ Прошивка ] ─ вложенное меню" \
			--menu "Иерархия: Главная › Прошивка\n\n★ п.2 — только отметить устройства (Пробел в списке)." 19 76 7 \
			1 "Подключить вручную: IP:PORT" \
			2 "★ Выбор устройств для прошивки (checklist → сохранить)" \
			3 "Установить APK на сохранённый список (после п.2)" \
			4 "Мастер: connect → APK → checklist → установка" \
			5 "Показать сохранённые цели" \
			0 "◀ Назад в главное меню") || break
		case "$b" in
		1) dialog_connect_ip ;;
		2) dialog_flash_checklist ;;
		3) dialog_install_saved ;;
		4) dialog_install_wizard ;;
		5) dialog_show_saved ;;
		0) break ;;
		esac
	done
}

dialog_connect_ip() {
	addr=$(dialog --stdout --title "[ Прошивка › connect ]" \
		--inputbox "ADB адрес как IP:PORT или host:PORT:" 10 70 "192.168.1.211:${ADB_PORT:-5555}") || return
	[ -z "$addr" ] && return
	is_adb_target "$addr" || {
		dialog --msgbox "Нужен формат host:port" 6 40
		return
	}
	adb connect "$addr"
	dialog --msgbox "Команда выполнена. Проверьте список в главном меню (п.4)." 7 60
}

dialog_flash_checklist() {
	load_settings
	ensure_adb
	sf=$(mktemp)
	refresh_serials_file "$sf"
	if [ ! -s "$sf" ]; then
		dialog --msgbox "Нет устройств в состоянии device." 6 50
		rm -f "$sf"
		return
	fi
	n=$(wc -l <"$sf" | tr -d ' ')
	lh=$n
	[ "$lh" -gt 12 ] && lh=12
	h=$((lh + 8))
	args=""
	i=1
	while read -r ser; do
		[ -z "$ser" ] && continue
		args="$args $i $ser off"
		i=$((i + 1))
	done <"$sf"
	sel=$(dialog --stdout --separate-output \
		--title "[ Прошивка › выбор целей ]" \
		--checklist "Пробел — отметить / снять. Enter — OK." "$h" 78 "$lh" $args) || {
		rm -f "$sf"
		return
	}
	out=$(selected_targets_file)
	mkdir -p "$(dirname "$out")"
	: >"$out"
	for t in $sel; do
		sed -n "${t}p" "$sf" >>"$out"
	done
	rm -f "$sf"
	nc=$(wc -l <"$out" | tr -d ' ')
	if [ "${nc:-0}" -eq 0 ]; then
		dialog --msgbox "Ничего не отмечено." 5 40
		return
	fi
	dialog --msgbox "Сохранено устройств: $nc\nДалее: п.3 «Установить APK на сохранённый список»." 8 65
}

dialog_show_saved() {
	f=$(selected_targets_file)
	if [ ! -s "$f" ]; then
		dialog --msgbox "Список целей пуст. Используйте п.2." 6 50
		return
	fi
	dialog --title "[ сохранённые serial ]" --textbox "$f" 16 72
}

dialog_install_saved() {
	f=$(selected_targets_file)
	if [ ! -s "$f" ]; then
		dialog --msgbox "Сначала: Прошивка › п.2 — выбор устройств." 7 55
		return
	fi
	apk=$(dialog --stdout --title "[ APK ]" --inputbox "Путь к .apk или имя из каталога apks/:" 11 72 "") || return
	[ -z "$apk" ] && return
	ap=$apk
	[ ! -f "$ap" ] && [ -f "apks/$apk" ] && ap="apks/$apk"
	if [ ! -f "$ap" ]; then
		dialog --msgbox "Файл не найден: $apk" 6 50
		return
	fi
	dialog --yesno "Установить $(basename "$ap") на отмеченные устройства?" 7 65 || return
	err=0
	while read -r s; do
		[ -z "$s" ] && continue
		adb -s "$s" install -r "$ap" || err=1
	done <"$f"
	[ "$err" -eq 0 ] && dialog --msgbox "Готово." 5 35 || dialog --msgbox "Были ошибки (см. вывод adb)." 6 45
}

dialog_install_wizard() {
	load_settings
	ensure_adb
	addr=$(dialog --stdout --title "[ Мастер ]" --inputbox "ADB IP:PORT [пусто — пропуск]:" 10 70 "") || return
	if [ -n "$addr" ] && is_adb_target "$addr"; then
		adb connect "$addr" || true
	fi
	apk=$(dialog --stdout --inputbox "Путь к APK:" 10 70 "") || return
	[ -z "$apk" ] && return
	ap=$apk
	[ ! -f "$ap" ] && [ -f "apks/$apk" ] && ap="apks/$apk"
	if [ ! -f "$ap" ]; then
		dialog --msgbox "Файл не найден." 5 35
		return
	fi
	sf=$(mktemp)
	refresh_serials_file "$sf"
	if [ ! -s "$sf" ]; then
		rm -f "$sf"
		dialog --msgbox "Нет device." 5 35
		return
	fi
	n=$(wc -l <"$sf" | tr -d ' ')
	lh=$n
	[ "$lh" -gt 12 ] && lh=12
	h=$((lh + 8))
	args=""
	i=1
	while read -r ser; do
		[ -z "$ser" ] && continue
		args="$args $i $ser off"
		i=$((i + 1))
	done <"$sf"
	selmust=$(dialog --stdout --separate-output \
		--title "[ Мастер › куда ставить ]" \
		--checklist "Отметьте устройства для $(basename "$ap")" "$h" 78 "$lh" $args) || {
		rm -f "$sf"
		return
	}
	p=$(mktemp)
	: >"$p"
	for t in $selmust; do
		sed -n "${t}p" "$sf" >>"$p"
	done
	rm -f "$sf"
	[ ! -s "$p" ] && {
		rm -f "$p"
		dialog --msgbox "Не выбрано ни одного." 5 40
		return
	}
	dialog --yesno "Подтвердить установку?" 6 50 || {
		rm -f "$p"
		return
	}
	err=0
	while read -r s; do
		[ -z "$s" ] && continue
		adb -s "$s" install -r "$ap" || err=1
	done <"$p"
	rm -f "$p"
	[ "$err" -eq 0 ] && dialog --msgbox "Готово." 5 35 || dialog --msgbox "Ошибки при установке." 6 40
}

dialog_settings() {
	load_settings
	p=$(dialog --stdout --inputbox "Порт ADB:" 8 60 "$ADB_PORT") || return
	[ -n "$p" ] && ADB_PORT=$p
	s=$(dialog --stdout --inputbox "Подсеть (3 октета):" 8 60 "$SCAN_SUBNET") || return
	[ -n "$s" ] && SCAN_SUBNET=$s
	save_settings
	dialog --msgbox "Сохранено." 5 35
}

# ═══════════════ текст: псевдографика ═══════════════
text_hline() {
	w=$1
	j=0
	printf '┌'
	while [ "$j" -lt "$w" ]; do
		printf '─'
		j=$((j + 1))
	done
	printf '┐\n'
}

text_hline_mid() {
	w=$1
	j=0
	printf '├'
	while [ "$j" -lt "$w" ]; do
		printf '─'
		j=$((j + 1))
	done
	printf '┤\n'
}

text_hline_bot() {
	w=$1
	j=0
	printf '└'
	while [ "$j" -lt "$w" ]; do
		printf '─'
		j=$((j + 1))
	done
	printf '┘\n'
}

text_flash_menu_txt() {
	while true; do
		printf '\n'
		text_hline 58
		printf '│ %s\n' " lunafast ▶ Прошивка (вложенное меню)                    │"
		text_hline_mid 58
		printf '│  1) Подключить IP:PORT                                   │\n'
		printf '│  2) ★ Выбор устройств → файл (для п.3)                   │\n'
		printf '│  3) Установить APK на сохранённый список                 │\n'
		printf '│  4) Мастер (connect → APK → номера)                      │\n'
		printf '│  5) Показать сохранённые serial                          │\n'
		printf '│  0) ◀ Назад                                              │\n'
		text_hline_bot 58
		printf '%s' "Выбор [0-5]: "
		read -r b || return
		case "$b" in
		1)
			printf '%s' "IP:PORT: "
			read -r a || return
			[ -n "$a" ] && is_adb_target "$a" && adb connect "$a"
			;;
		2) text_flash_checklist_txt ;;
		3) text_install_saved_txt ;;
		4) menu_install_text ;;
		5)
			f=$(selected_targets_file)
			if [ -s "$f" ]; then cat "$f"; else printf '%s\n' "(пусто)"; fi
			read -r _
			;;
		0) break ;;
		esac
	done
}

text_flash_checklist_txt() {
	load_settings
	sf=$(mktemp)
	refresh_serials_file "$sf"
	if [ ! -s "$sf" ]; then
		printf '%s\n' "Нет device."
		rm -f "$sf"
		read -r _
		return
	fi
	printf '%s\n' "Отметьте номера через пробел (Enter = все):"
	print_numbered_txt "$sf"
	printf '%s' "Номера: "
	read -r pick || {
		rm -f "$sf"
		return
	}
	out=$(selected_targets_file)
	mkdir -p "$(dirname "$out")"
	p=$(mktemp)
	if ! pick_serials_to_file "$sf" "$pick" "$p"; then
		rm -f "$sf" "$p"
		read -r _
		return
	fi
	mv "$p" "$out"
	rm -f "$sf"
	printf '%s\n' "Сохранено в $out"
	read -r _
}

text_install_saved_txt() {
	f=$(selected_targets_file)
	if [ ! -s "$f" ]; then
		printf '%s\n' "Сначала п.2 выбора."
		read -r _
		return
	fi
	printf '%s' "Путь к APK: "
	read -r path || return
	[ -z "$path" ] && return
	ap=$path
	[ ! -f "$ap" ] && [ -f "apks/$path" ] && ap="apks/$path"
	if [ ! -f "$ap" ]; then
		printf '%s\n' "Нет файла"
		read -r _
		return
	fi
	while read -r s; do
		[ -z "$s" ] && continue
		adb -s "$s" install -r "$ap" || true
	done <"$f"
	read -r _
}

print_numbered_txt() {
	sf=$1
	i=1
	while read -r L; do
		[ -z "$L" ] && continue
		printf '   %s) %s\n' "$i" "$L"
		i=$((i + 1))
	done <"$sf"
}

menu_install_text() {
	load_settings
	printf '%s' "IP:PORT [Enter пропуск]: "
	read -r addr
	[ -n "$addr" ] && is_adb_target "$addr" && adb connect "$addr"
	sf=$(mktemp)
	p=$(mktemp)
	refresh_serials_file "$sf"
	if [ ! -s "$sf" ]; then
		rm -f "$sf" "$p"
		read -r _
		return
	fi
	printf '%s' "APK: "
	read -r apk || {
		rm -f "$sf" "$p"
		return
	}
	ap=$apk
	[ ! -f "$ap" ] && [ -f "apks/$apk" ] && ap="apks/$apk"
	if [ ! -f "$ap" ]; then
		rm -f "$sf" "$p"
		read -r _
		return
	fi
	print_numbered_txt "$sf"
	printf '%s' "Номера устройств [Enter=all]: "
	read -r pick
	pick_serials_to_file "$sf" "$pick" "$p" || {
		rm -f "$sf" "$p"
		read -r _
		return
	}
	rm -f "$sf"
	while read -r s; do
		[ -z "$s" ] && continue
		adb -s "$s" install -r "$ap" || true
	done <"$p"
	rm -f "$p"
	read -r _
}

menu_settings_text() {
	load_settings
	printf '%s' "Порт [ $ADB_PORT ]: "
	read -r n
	[ -n "$n" ] && ADB_PORT=$n
	printf '%s' "Подсеть [ $SCAN_SUBNET ]: "
	read -r s
	[ -n "$s" ] && SCAN_SUBNET=$s
	save_settings
	printf '%s\n' "Сохранено: $(settings_file)"
	read -r _
}

text_search_flow() {
	load_settings
	printf '%s\n' "… скан …"
	run_scan_connect
	adb devices -l
	while true; do
		printf '%s\n' "  1) Мастер прошивки  2) Повтор  0) Назад"
		printf '%s' "? "
		read -r z || return
		case "$z" in
		1) menu_install_text ;;
		2) text_search_flow; return ;;
		0) break ;;
		esac
	done
}

text_main() {
	ensure_adb
	[ -n "$CONNECT_LIST" ] && connect_explicit_list
	while true; do
		load_settings
		printf '\n'
		text_hline 58
		printf '│ %s\n' " lunafast-fw-upload │ Главное меню (текст)              │"
		text_hline_mid 58
		printf '│  1) Сеть › поиск                                       │\n'
		printf '│  2) Прошивка › вложенное меню                          │\n'
		printf '│  3) Настройки                                          │\n'
		printf '│  4) adb devices -l                                     │\n'
		printf '│  0) Выход                                              │\n'
		text_hline_bot 58
		adb devices -l
		printf '%s' "[0-4]: "
		read -r c || exit 0
		case "$c" in
		1) text_search_flow ;;
		2) text_flash_menu_txt ;;
		3) menu_settings_text ;;
		4) ;;
		0) exit 0 ;;
		esac
	done
}

install_apk_batch() {
	[ -f "$1" ] || exit 1
	load_settings
	ensure_adb
	[ -n "$CONNECT_LIST" ] && connect_explicit_list
	list=$(adb_device_serials)
	[ -z "$list" ] && exit 1
	e=0
	for s in $list; do
		adb -s "$s" install -r "$1" || e=1
	done
	exit "$e"
}

# ═══ entry ═══
MENU=
NO_UI=
APK=
CONNECT_LIST=

while [ $# -gt 0 ]; do
	case "$1" in
	--connect)
		shift
		[ -z "$1" ] && exit 1
		is_adb_target "$1" || exit 1
		CONNECT_LIST="$CONNECT_LIST${CONNECT_LIST:+ }$1"
		shift
		;;
	-m | --menu) MENU=1; shift ;;
	--no-ui) NO_UI=1; shift ;;
	-h | --help) usage; exit 0 ;;
	--) shift; break ;;
	-*) usage >&2; exit 1 ;;
	*) break ;;
	esac
done

[ $# -gt 0 ] && APK=$1

if [ -n "$APK" ]; then install_apk_batch "$APK"; exit $?; fi
if [ -n "$NO_UI" ]; then quick_batch; exit 0; fi

if [ -n "$MENU" ] || { [ -t 0 ] && [ -t 1 ]; }; then
	ensure_adb
	if ! have_dialog; then
		printf '%s\n' "Подсказка: apt install dialog — меню со стрелками и checklist."
		text_main
	else
		dialog_main
	fi
	exit 0
fi

quick_batch
