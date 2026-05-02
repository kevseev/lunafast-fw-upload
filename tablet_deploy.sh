#!/bin/sh
# lunafast-fw-upload — поиск ADB в LAN, прошивка APK/XAPK, настройки.
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

# Каталог проекта: рядом с tablet_deploy.sh (или CWD, если скрипт без пути в argv)
lunafast_project_root() {
	case "$0" in
	*/*) (cd "${0%/*}" && pwd) ;;
	*) pwd ;;
	esac
}

# Один журнал установок в каталоге проекта (переопределение: LUNAFAST_LOG=/путь/к/файлу)
lunafast_project_log_path() {
	if [ -n "${LUNAFAST_LOG:-}" ]; then
		printf '%s\n' "$LUNAFAST_LOG"
		return
	fi
	printf '%s/lunafast_install.log\n' "$(lunafast_project_root)"
}

# Начало блока в журнале (время в каждом фрагменте)
lunafast_begin_log_section() {
	_f=$1
	_note=${2:-}
	_ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || _ts=$(date)
	_d=$(dirname "$_f")
	if [ ! -d "$_d" ]; then
		mkdir -p "$_d" 2>/dev/null || return 1
	fi
	{
		printf '\n'
		printf '%s\n' "################################################################"
		printf '%s\n' "## $_ts — начало записи"
		[ -n "$_note" ] && printf '%s\n' "## $_note"
		printf '%s\n' "################################################################"
		printf '%s\n' ""
	} >>"$_f" || return 1
}

lunafast_end_log_section() {
	_f=$1
	_ret=$2
	_ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || _ts=$(date)
	{
		printf '%s\n' ""
		printf '%s\n' "## $_ts — конец записи · код возврата: $_ret"
		printf '%s\n' "################################################################"
		printf '\n'
	} >>"$_f" 2>/dev/null || true
}

# Сессию установки — в начало общего журнала (свежее сверху)
lunafast_prepend_session_to_project_log() {
	_sess=$1
	_dst=$(lunafast_project_log_path)
	_d=$(dirname "$_dst")
	[ -n "$_sess" ] || return 1
	[ -f "$_sess" ] || return 1
	mkdir -p "$_d" 2>/dev/null || {
		rm -f "$_sess"
		return 1
	}
	if [ ! -s "$_sess" ]; then
		rm -f "$_sess"
		return 0
	fi
	if [ ! -f "$_dst" ] || [ ! -s "$_dst" ]; then
		mv "$_sess" "$_dst" 2>/dev/null || {
			rm -f "$_sess"
			return 1
		}
		return 0
	fi
	_out=$(mktemp "$_d/.lunafast_jnl.XXXXXX") || {
		rm -f "$_sess"
		return 1
	}
	{
		cat "$_sess"
		printf '\n'
		cat "$_dst"
	} >"$_out" || {
		rm -f "$_out" "$_sess"
		return 1
	}
	mv "$_out" "$_dst" || {
		rm -f "$_out" "$_sess"
		return 1
	}
	rm -f "$_sess"
}

usage() {
	printf '%s\n' "Использование: tablet_deploy.sh [опции] [файл.apk|.xapk]
  Интерфейс: dialog (меню со стрелками), если установлен пакет «dialog».
  -m, --menu      меню
  --no-ui         быстрый adb connect + devices
  --connect H:P   (повторимо) явный connect; с .apk/.xapk — ставит на все device
  -h, --help

  --selftest      проверка синтаксиса, темы dialog и нормализации вывода (без устройств)

  Журнал: lunafast_install.log — новые записи добавляются в начало файла (сверху последняя операция).

  UI без dialog: текстовые рамки. apt install dialog (Debian/Ubuntu).
В меню: серо-белая тема; при установке APK — шкала до 100% только после успешного pm install (копирование ≈0–85%, по %/байтам из adb или оценочно). XAPK: unzip."
}

ensure_adb() {
	command -v adb >/dev/null 2>&1 || {
		printf '%s\n' "Нет adb в PATH." >&2
		exit 1
	}
}

# Терминал: очистка перед меню (серые окна dialog без цветного фона)
lunafast_term_tty() {
	[ -t 1 ] && [ -t 2 ] && return 0
	return 1
}

lunafast_term_blue_fill() {
	lunafast_term_tty || return 0
	# Нейтральный экран под серые окна dialog (без синей заливки)
	printf '\033[0m\033[2J\033[H'
}

lunafast_term_restore() {
	lunafast_term_tty || return 0
	printf '\033[0m'
}

lunafast_adb_push_has_progress() {
	adb push --help 2>&1 | grep -q '\-\-progress' || adb --help 2>&1 | grep -q '\-\-progress'
}

# adb: построчная буферизация вывода (прогресс push чаще попадает в файл)
lunafast_adb_linebuf() {
	if command -v stdbuf >/dev/null 2>&1; then
		stdbuf -oL -eL adb "$@"
	else
		adb "$@"
	fi
}

lunafast_dialog_has_prgbox() {
	command -v dialog >/dev/null 2>&1 || return 1
	dialog --help 2>&1 | grep -q '\-\-prgbox'
}

lunafast_dialog_has_gauge() {
	command -v dialog >/dev/null 2>&1 || return 1
	dialog --help 2>&1 | grep -q '\-\-gauge'
}

# Доля из вывода adb push (--progress или текстовые сообщения)
lunafast_push_pct_from_file() {
	[ ! -f "$1" ] && return
	tr '\r' '\n' <"$1" 2>/dev/null | grep -oE '[0-9]+%' | tail -1 | tr -dc '0-9'
}

# 0–100: из adb push --progress (%), иначе из «(N bytes in …)» и размера файла
lunafast_push_xfer_pct() {
	_tmp=$1
	_tot=$2
	[ ! -f "$_tmp" ] && return
	[ -z "$_tot" ] || [ "$_tot" -le 0 ] 2>/dev/null && return
	_p=$(lunafast_push_pct_from_file "$_tmp")
	if [ -n "$_p" ]; then
		printf '%s\n' "$_p"
		return
	fi
	_mx=$(tr '\r' '\n' <"$_tmp" 2>/dev/null | sed -n 's/.*(\([0-9][0-9]*\) bytes in.*/\1/p' | sort -n | tail -1)
	[ -z "$_mx" ] && return
	[ "$_mx" -gt "$_tot" ] 2>/dev/null && _mx=$_tot
	_p=$((_mx * 100 / _tot))
	[ "$_p" -gt 100 ] && _p=100
	printf '%s\n' "$_p"
}

# Лог вывода push: \r → newline (иначе итоговая строка «обрезана», например 9.8 MB/)
lunafast_log_push_output() {
	_logf=$1
	_tmp=$2
	_ec=$3
	{
		printf '%s\n' "--- adb push (полный вывод) ---"
		tr '\r' '\n' <"$_tmp" 2>/dev/null
		printf '%s\n' "--- код выхода push: $_ec ---"
	} >>"$_logf"
}

# pm после push — в журнал (для объединённой шкалы с копированием)
lunafast_pm_steps_to_log() {
	_s=$1
	_rmt=$2
	_pkg=$3
	_log=$4
	ec=0
	{
		printf '%s\n' "########################################"
		printf '%s\n' "# serial: $_s (pm после push)"
		printf '%s\n' "########################################"
		printf '%s\n' "--- adb get-state ---"
		lunafast_adb_linebuf -s "$_s" get-state 2>&1 || true
		if [ -n "${_pkg:-}" ]; then
			printf '%s\n' "--- проверка: уже установлен ${_pkg}? ---"
			_pp=$(lunafast_adb_linebuf -s "$_s" shell pm path "$_pkg" 2>/dev/null) || _pp=
			case "$_pp" in
			package:*)
				printf '%s\n' "--- pm uninstall (снять текущую/старую версию) ---"
				lunafast_adb_linebuf -s "$_s" uninstall "$_pkg" 2>&1 || lunafast_adb_linebuf -s "$_s" shell pm uninstall --user 0 "$_pkg" 2>&1 || true
				;;
			*)
				printf '%s\n' "(пакет на устройстве не найден — ставим с нуля)"
				;;
			esac
		fi
		printf '%s\n' "--- pm install -r -g -t $_rmt ---"
		lunafast_adb_linebuf -s "$_s" shell pm install -r -g -t "$_rmt" 2>&1 || ec=$?
		lunafast_adb_linebuf -s "$_s" shell rm -f "$_rmt" 2>/dev/null || true
		printf '%s\n' "--- код выхода install: $ec ---"
		if [ "$ec" -eq 0 ] && [ -n "${_pkg:-}" ]; then
			printf '%s\n' "--- Проверка: pm path ${_pkg} ---"
			lunafast_adb_linebuf -s "$_s" shell pm path "$_pkg" 2>&1 || true
			printf '%s\n' "--- pm list packages (фильтр по имени) ---"
			lunafast_adb_linebuf -s "$_s" shell pm list packages -f 2>&1 | grep -F "$_pkg" || printf '%s\n' "(пакет не в list — см. выше)"
			printf '%s\n' "--- версия (dumpsys, фрагмент) ---"
			lunafast_adb_linebuf -s "$_s" shell dumpsys package "$_pkg" 2>&1 | grep -E 'versionName|versionCode|firstInstallTime|lastUpdateTime' | head -10 || true
		elif [ "$ec" -eq 0 ]; then
			printf '%s\n' "(Имя пакета неизвестно — pm verify пропуск.)"
		else
			printf '%s\n' "ОШИБКА установки — см. вывод adb выше."
		fi
		printf '%s\n' ""
	} >>"$_log" 2>&1
	return "$ec"
}

# Шкала 0–100%: до ~85% — копирование (по % adb или по байтам/пульс), затем установка; 100% только после успешного pm
lunafast_dialog_gauge_apk_install() {
	ser=$1
	loc=$2
	rem=$3
	logf=$4
	pkg=$5
	tmp=$(mktemp) || return 1
	ecf=$(mktemp) || {
		rm -f "$tmp"
		return 1
	}
	(
		PATH="/usr/bin:/bin:/usr/local/bin:/usr/lib/android-sdk/platform-tools:${PATH:-}"
		export PATH
		if ! command -v adb >/dev/null 2>&1; then
			printf '%s\n' "127" >"$ecf"
			rm -f "$tmp"
			printf '%s\n' "0"
			printf '%s\n' "Ошибка: adb не в PATH"
		else
			tot=$(wc -c <"$loc" | tr -d ' ')
			if lunafast_adb_push_has_progress; then
				adb -s "$ser" push --progress "$loc" "$rem" >>"$tmp" 2>&1 &
			else
				lunafast_adb_linebuf -s "$ser" push "$loc" "$rem" >>"$tmp" 2>&1 &
			fi
			pp=$!
			pulse=0
			while kill -0 "$pp" 2>/dev/null; do
				xfer=$(lunafast_push_xfer_pct "$tmp" "$tot")
				if [ -n "$xfer" ] && [ "$xfer" -ge 0 ] 2>/dev/null && [ "$xfer" -le 100 ] 2>/dev/null; then
					pct=$((xfer * 85 / 100))
					[ "$pct" -gt 85 ] && pct=85
				else
					pulse=$((pulse + 1))
					[ "$pulse" -gt 84 ] && pulse=84
					pct=$pulse
				fi
				printf '%s\n' "$pct"
				printf '%s\n' "Копирование на $ser — $(basename "$loc") (до 85% шкалы — только передача файла)"
				sleep 0.16
			done
			wait "$pp"
			ec_push=$?
			lunafast_log_push_output "$logf" "$tmp" "$ec_push"
			rm -f "$tmp"
			if [ "$ec_push" -ne 0 ]; then
				printf '%s\n' "$ec_push" >"$ecf"
				printf '%s\n' "0"
				printf '%s\n' "Ошибка копирования на устройство"
			else
				printf '%s\n' "85"
				printf '%s\n' "Файл на устройстве — установка (pm)…"
				pmecf=$(mktemp) || pmecf=
				if [ -n "$pmecf" ] && [ -f "$pmecf" ]; then
					(
						lunafast_pm_steps_to_log "$ser" "$rem" "$pkg" "$logf"
						ec_pm=$?
						printf '%s\n' "$ec_pm" >"$pmecf"
					) &
					pmp=$!
					pm_ui=85
					while kill -0 "$pmp" 2>/dev/null; do
						[ "$pm_ui" -lt 98 ] && pm_ui=$((pm_ui + 1))
						printf '%s\n' "$pm_ui"
						printf '%s\n' "Установка пакета (pm install), ждите…"
						sleep 0.22
					done
					wait "$pmp"
					read -r ec_fin <"$pmecf" || ec_fin=1
					rm -f "$pmecf"
					[ -z "$ec_fin" ] && ec_fin=1
					case "$ec_fin" in *[!0-9]*) ec_fin=1 ;; esac
					printf '%s\n' "$ec_fin" >"$ecf"
					if [ "$ec_fin" -eq 0 ]; then
						printf '%s\n' "100"
						printf '%s\n' "Готово: скопировано и установлено"
					else
						printf '%s\n' "97"
						printf '%s\n' "Ошибка установки — см. журнал"
					fi
				else
					printf '%s\n' "1" >"$ecf"
					printf '%s\n' "85"
					printf '%s\n' "Внутренняя ошибка (mktemp)"
				fi
			fi
		fi
	) | dialog --clear --gauge "Установка: копирование → pm (100% = всё готово на устройстве)" 14 78 0 || true
	read -r ec <"$ecf" || ec=1
	rm -f "$ecf"
	case "$ec" in *[!0-9]*) ec=1 ;; esac
	return "$ec"
}

lunafast_dialog_has_tailboxbg() {
	command -v dialog >/dev/null 2>&1 || return 1
	dialog --help 2>&1 | grep -q tailboxbg
}

# Аргумент для sh: '...' с экранированием встроенных '
lunafast_sq() {
	_s=$1
	case $_s in
	*\'*) printf "'"; printf '%s' "$_s" | sed "s/'/'\"'\"'/g"; printf "'\n" ;;
	*) printf "'%s'\n" "$_s" ;;
	esac
}

# Переменные для runner внутри обёртки dialog (prgbox не наследует export родителя)
lunafast_embed_runner_env() {
	printf '%s\n' "export LUNAFAST_EC_FILE=$(lunafast_sq "$1")"
	printf '%s\n' "export LUNAFAST_R=$(lunafast_sq "$2")"
	printf '%s\n' "export LUNAFAST_LOGF=$(lunafast_sq "$3")"
	[ -n "${LUNAFAST_S:-}" ] && printf '%s\n' "export LUNAFAST_S=$(lunafast_sq "$LUNAFAST_S")"
	[ -n "${LUNAFAST_RMT:-}" ] && printf '%s\n' "export LUNAFAST_RMT=$(lunafast_sq "$LUNAFAST_RMT")"
	[ -n "${LUNAFAST_PKG:-}" ] && printf '%s\n' "export LUNAFAST_PKG=$(lunafast_sq "$LUNAFAST_PKG")"
	[ -n "${LUNAFAST_A:-}" ] && printf '%s\n' "export LUNAFAST_A=$(lunafast_sq "$LUNAFAST_A")"
	[ -n "${LUNAFAST_OLIST:-}" ] && printf '%s\n' "export LUNAFAST_OLIST=$(lunafast_sq "$LUNAFAST_OLIST")"
}

lunafast_stream_runner() {
	runner=$1
	logf=$2
	title=$3
	ecf=$(mktemp) || return 1
	export LUNAFAST_EC_FILE="$ecf"
	if [ -n "$LUNAFAST_DIALOG_LIVE" ] && lunafast_dialog_has_prgbox; then
		hlp=$(mktemp) || {
			rm -f "$ecf"
			return 1
		}
		{
			printf '%s\n' '#!/bin/sh'
			printf '%s\n' 'PATH="/usr/bin:/bin:/usr/local/bin:/usr/lib/android-sdk/platform-tools:${PATH:-}"'
			printf '%s\n' 'export PATH'
			lunafast_embed_runner_env "$ecf" "$runner" "$logf"
			cat <<'EOS'
sh "$LUNAFAST_R" 2>&1 | {
	if command -v stdbuf >/dev/null 2>&1; then
		stdbuf -i0 -o0 -e0 tr '\r' '\n'
	else
		tr '\r' '\n'
	fi
} | {
	if command -v stdbuf >/dev/null 2>&1; then
		stdbuf -oL -eL tee -a "$LUNAFAST_LOGF"
	else
		tee -a "$LUNAFAST_LOGF"
	fi
}
EOS
		} >"$hlp"
		chmod +x "$hlp"
		dialog --clear --colors --title "$title" --prgbox "Установка (Enter — закрыть окно)" "$hlp" 28 92 || true
		rm -f "$hlp"
	elif [ -n "$LUNAFAST_DIALOG_LIVE" ] && lunafast_dialog_has_tailboxbg; then
		chunk=$(mktemp) || {
			rm -f "$ecf"
			return 1
		}
		: >"$chunk"
		tbw=$(mktemp) || {
			rm -f "$ecf" "$chunk"
			return 1
		}
		{
			printf '%s\n' '#!/bin/sh'
			printf '%s\n' 'PATH="/usr/bin:/bin:/usr/local/bin:/usr/lib/android-sdk/platform-tools:${PATH:-}"'
			printf '%s\n' 'export PATH'
			lunafast_embed_runner_env "$ecf" "$runner" "$logf"
			printf '%s\n' "export LUNAFAST_CHUNK=$(lunafast_sq "$chunk")"
			cat <<'EOS'
sh "$LUNAFAST_R" 2>&1 | {
	if command -v stdbuf >/dev/null 2>&1; then
		stdbuf -i0 -o0 -e0 tr '\r' '\n'
	else
		tr '\r' '\n'
	fi
} | {
	if command -v stdbuf >/dev/null 2>&1; then
		stdbuf -oL -eL tee -a "$LUNAFAST_CHUNK" "$LUNAFAST_LOGF"
	else
		tee -a "$LUNAFAST_CHUNK" "$LUNAFAST_LOGF"
	fi
} >/dev/null
EOS
		} >"$tbw"
		chmod +x "$tbw"
		( sh "$tbw" ) &
		_adbjob=$!
		dialog --clear --colors --title "$title" --tailboxbg "$chunk" 28 92 || true
		wait "$_adbjob" 2>/dev/null
		rm -f "$tbw" "$chunk"
	else
		sh "$runner" 2>&1 | {
			if command -v stdbuf >/dev/null 2>&1; then
				stdbuf -i0 -o0 -e0 tr '\r' '\n'
			else
				tr '\r' '\n'
			fi
		} | {
			if command -v stdbuf >/dev/null 2>&1; then
				stdbuf -oL -eL tee -a "$logf"
			else
				tee -a "$logf"
			fi
		}
	fi
	read -r ec <"$ecf" || ec=1
	[ -z "$ec" ] && ec=1
	case "$ec" in *[!0-9]*) ec=1 ;; esac
	rm -f "$ecf"
	return "$ec"
}

# Скрипт: диагностика + push на устройство + pm install с /data/local/tmp
lunafast_write_runner_single_apk() {
	rf=$1
	cat >"$rf" <<'EOS'
#!/bin/sh
PATH="/usr/bin:/bin:/usr/local/bin:/usr/lib/android-sdk/platform-tools:${PATH:-}"
export PATH
set -f
run_adb() {
	if command -v stdbuf >/dev/null 2>&1; then
		stdbuf -oL -eL adb "$@"
	else
		adb "$@"
	fi
}
ec=0
: "${LUNAFAST_S:?}" "${LUNAFAST_A:?}" "${LUNAFAST_EC_FILE:?}"
rmt="/data/local/tmp/lunafast_inst_$$.apk"
printf '%s\n' "########################################"
printf '%s\n' "# serial: $LUNAFAST_S"
printf '%s\n' "########################################"
printf '%s\n' "--- adb get-state ---"
run_adb -s "$LUNAFAST_S" get-state 2>&1 || true
printf '%s\n' "--- adb shell echo ping ---"
run_adb -s "$LUNAFAST_S" shell echo ok 2>&1 || true
printf '%s\n' "--- adb push → $rmt ---"
run_adb -s "$LUNAFAST_S" push "$LUNAFAST_A" "$rmt" 2>&1 || ec=$?
if [ "$ec" -eq 0 ]; then
	if [ -n "${LUNAFAST_PKG:-}" ]; then
		printf '%s\n' "--- проверка: уже установлен $LUNAFAST_PKG? ---"
		_ppath=$(run_adb -s "$LUNAFAST_S" shell pm path "$LUNAFAST_PKG" 2>/dev/null) || _ppath=
		case "$_ppath" in
		package:*)
			printf '%s\n' "--- pm uninstall (снять текущую/старую версию) ---"
			run_adb -s "$LUNAFAST_S" uninstall "$LUNAFAST_PKG" 2>&1 || run_adb -s "$LUNAFAST_S" shell pm uninstall --user 0 "$LUNAFAST_PKG" 2>&1 || true
			;;
		*)
			printf '%s\n' "(пакет на устройстве не найден — ставим с нуля)"
			;;
		esac
	fi
	printf '%s\n' "--- pm install -r -g -t ---"
	run_adb -s "$LUNAFAST_S" shell pm install -r -g -t "$rmt" 2>&1 || ec=$?
fi
adb -s "$LUNAFAST_S" shell rm -f "$rmt" 2>/dev/null || true
printf '%s\n' "--- код выхода install: $ec ---"
if [ "$ec" -eq 0 ] && [ -n "${LUNAFAST_PKG:-}" ]; then
	printf '%s\n' "--- Проверка: pm path $LUNAFAST_PKG ---"
	run_adb -s "$LUNAFAST_S" shell pm path "$LUNAFAST_PKG" 2>&1 || true
	printf '%s\n' "--- pm list packages (фильтр по имени) ---"
	run_adb -s "$LUNAFAST_S" shell pm list packages -f 2>&1 | grep -F "$LUNAFAST_PKG" || printf '%s\n' "(пакет не в list — см. выше)"
	printf '%s\n' "--- версия (dumpsys, фрагмент) ---"
	run_adb -s "$LUNAFAST_S" shell dumpsys package "$LUNAFAST_PKG" 2>&1 | grep -E 'versionName|versionCode|firstInstallTime|lastUpdateTime' | head -10 || true
elif [ "$ec" -eq 0 ]; then
	printf '%s\n' "(Имя пакета неизвестно — pm verify пропуск.)"
else
	printf '%s\n' "ОШИБКА установки — см. вывод adb выше."
fi
printf '%s\n' ""
printf '%s\n' "$ec" >"$LUNAFAST_EC_FILE"
exit "$ec"
EOS
	chmod +x "$rf"
}

# Только pm install (если push уже выполнен вручную; основной UI — lunafast_dialog_gauge_apk_install)
lunafast_write_runner_pm_only() {
	rf=$1
	cat >"$rf" <<'EOS'
#!/bin/sh
PATH="/usr/bin:/bin:/usr/local/bin:/usr/lib/android-sdk/platform-tools:${PATH:-}"
export PATH
set -f
run_adb() {
	if command -v stdbuf >/dev/null 2>&1; then
		stdbuf -oL -eL adb "$@"
	else
		adb "$@"
	fi
}
ec=0
: "${LUNAFAST_S:?}" "${LUNAFAST_RMT:?}" "${LUNAFAST_EC_FILE:?}"
printf '%s\n' "########################################"
printf '%s\n' "# serial: $LUNAFAST_S (pm после push)"
printf '%s\n' "########################################"
printf '%s\n' "--- adb get-state ---"
run_adb -s "$LUNAFAST_S" get-state 2>&1 || true
if [ -n "${LUNAFAST_PKG:-}" ]; then
	printf '%s\n' "--- проверка: уже установлен $LUNAFAST_PKG? ---"
	_ppath=$(run_adb -s "$LUNAFAST_S" shell pm path "$LUNAFAST_PKG" 2>/dev/null) || _ppath=
	case "$_ppath" in
	package:*)
		printf '%s\n' "--- pm uninstall (снять текущую/старую версию) ---"
		run_adb -s "$LUNAFAST_S" uninstall "$LUNAFAST_PKG" 2>&1 || run_adb -s "$LUNAFAST_S" shell pm uninstall --user 0 "$LUNAFAST_PKG" 2>&1 || true
		;;
	*)
		printf '%s\n' "(пакет на устройстве не найден — ставим с нуля)"
		;;
	esac
fi
printf '%s\n' "--- pm install -r -g -t $LUNAFAST_RMT ---"
run_adb -s "$LUNAFAST_S" shell pm install -r -g -t "$LUNAFAST_RMT" 2>&1 || ec=$?
adb -s "$LUNAFAST_S" shell rm -f "$LUNAFAST_RMT" 2>/dev/null || true
printf '%s\n' "--- код выхода install: $ec ---"
if [ "$ec" -eq 0 ] && [ -n "${LUNAFAST_PKG:-}" ]; then
	printf '%s\n' "--- Проверка: pm path $LUNAFAST_PKG ---"
	run_adb -s "$LUNAFAST_S" shell pm path "$LUNAFAST_PKG" 2>&1 || true
	printf '%s\n' "--- pm list packages (фильтр по имени) ---"
	run_adb -s "$LUNAFAST_S" shell pm list packages -f 2>&1 | grep -F "$LUNAFAST_PKG" || printf '%s\n' "(пакет не в list — см. выше)"
	printf '%s\n' "--- версия (dumpsys, фрагмент) ---"
	run_adb -s "$LUNAFAST_S" shell dumpsys package "$LUNAFAST_PKG" 2>&1 | grep -E 'versionName|versionCode|firstInstallTime|lastUpdateTime' | head -10 || true
elif [ "$ec" -eq 0 ]; then
	printf '%s\n' "(Имя пакета неизвестно — pm verify пропуск.)"
else
	printf '%s\n' "ОШИБКА установки — см. вывод adb выше."
fi
printf '%s\n' ""
printf '%s\n' "$ec" >"$LUNAFAST_EC_FILE"
exit "$ec"
EOS
	chmod +x "$rf"
}

# Несколько APK из XAPK: install-multiple (прогресс adb показывает по своему)
lunafast_write_runner_install_multiple() {
	rf=$1
	cat >"$rf" <<'EOS'
#!/bin/sh
PATH="/usr/bin:/bin:/usr/local/bin:/usr/lib/android-sdk/platform-tools:${PATH:-}"
export PATH
set -f
run_adb() {
	if command -v stdbuf >/dev/null 2>&1; then
		stdbuf -oL -eL adb "$@"
	else
		adb "$@"
	fi
}
ec=0
: "${LUNAFAST_S:?}" "${LUNAFAST_OLIST:?}" "${LUNAFAST_EC_FILE:?}"
printf '%s\n' "########################################"
printf '%s\n' "# serial: $LUNAFAST_S"
printf '%s\n' "########################################"
printf '%s\n' "--- adb get-state ---"
run_adb -s "$LUNAFAST_S" get-state 2>&1 || true
printf '%s\n' "--- adb shell echo ping ---"
run_adb -s "$LUNAFAST_S" shell echo ok 2>&1 || true
if [ -n "${LUNAFAST_PKG:-}" ]; then
	printf '%s\n' "--- проверка: уже установлен $LUNAFAST_PKG? ---"
	_ppath=$(run_adb -s "$LUNAFAST_S" shell pm path "$LUNAFAST_PKG" 2>/dev/null) || _ppath=
	case "$_ppath" in
	package:*)
		printf '%s\n' "--- pm uninstall (снять текущую/старую версию) ---"
		run_adb -s "$LUNAFAST_S" uninstall "$LUNAFAST_PKG" 2>&1 || run_adb -s "$LUNAFAST_S" shell pm uninstall --user 0 "$LUNAFAST_PKG" 2>&1 || true
		;;
	*)
		printf '%s\n' "(пакет на устройстве не найден — ставим с нуля)"
		;;
	esac
fi
printf '%s\n' "--- adb install-multiple (сплиты из XAPK, вывод в потоке) ---"
set --
while read -r apkf || [ -n "$apkf" ]; do
	[ -z "$apkf" ] && continue
	set -- "$@" "$apkf"
done <"$LUNAFAST_OLIST"
if [ "$#" -eq 0 ]; then
	ec=1
else
	run_adb -s "$LUNAFAST_S" install-multiple -r -g -t -- "$@" 2>&1 || ec=$?
fi
printf '%s\n' "--- код выхода install: $ec ---"
if [ "$ec" -eq 0 ] && [ -n "${LUNAFAST_PKG:-}" ]; then
	printf '%s\n' "--- Проверка: pm path $LUNAFAST_PKG ---"
	run_adb -s "$LUNAFAST_S" shell pm path "$LUNAFAST_PKG" 2>&1 || true
	printf '%s\n' "--- pm list packages (фильтр) ---"
	run_adb -s "$LUNAFAST_S" shell pm list packages -f 2>&1 | grep -F "$LUNAFAST_PKG" || printf '%s\n' "(пакет не в list)"
	printf '%s\n' "--- версия (dumpsys, фрагмент) ---"
	run_adb -s "$LUNAFAST_S" shell dumpsys package "$LUNAFAST_PKG" 2>&1 | grep -E 'versionName|versionCode|firstInstallTime|lastUpdateTime' | head -10 || true
elif [ "$ec" -ne 0 ]; then
	printf '%s\n' "ОШИБКА установки — см. вывод adb выше."
fi
printf '%s\n' ""
printf '%s\n' "$ec" >"$LUNAFAST_EC_FILE"
exit "$ec"
EOS
	chmod +x "$rf"
}

apk_abspath() {
	f=$1
	d=$(dirname "$f") || return 1
	b=$(basename "$f")
	[ -d "$d" ] || return 1
	d=$( (cd "$d" && pwd) ) || return 1
	printf '%s/%s\n' "$d" "$b"
}

# Имя пакета из APK (для проверки на устройстве)
detect_pkg_from_apk() {
	apk=$1
	if command -v aapt >/dev/null 2>&1; then
		aapt dump badging "$apk" 2>/dev/null | head -1 | sed -n "s/.*package: name='\\([^']*\\)'.*/\\1/p"
		return
	fi
	if command -v aapt2 >/dev/null 2>&1; then
		aapt2 dump badging "$apk" 2>/dev/null | head -1 | sed -n "s/.*package: name='\\([^']*\\)'.*/\\1/p"
	fi
}

# Очистка serial (CRLF, пробелы)
serial_clean() {
	printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Нижний регистр последнего суффикса
path_lower_suffix() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_xapk_path() {
	case $(path_lower_suffix "$1") in *.xapk) return 0 ;; *) return 1 ;; esac
}

# APK и XAPK в apks/ и текущем каталоге (для меню; один файл — одна строка после нормализации пути)
collect_install_candidates() {
	{
		for d in apks .; do
			[ -d "$d" ] || continue
			find "$d" -maxdepth 5 \( -iname '*.apk' -o -iname '*.xapk' \) -type f 2>/dev/null
		done
	} | while read -r L; do
		[ -z "$L" ] && continue
		norm=$(apk_abspath "$L" 2>/dev/null) || norm=$L
		printf '%s\n' "$norm"
	done | sort -u
}

resolve_installable_path() {
	raw=$1
	[ -z "$raw" ] && return 1
	for c in "$raw" "apks/$raw"; do
		if [ -f "$c" ]; then
			apk_abspath "$c"
			return $?
		fi
	done
	return 1
}

# Расширенная тема dialog: классические серо-белые окна (как типичный новодialog)
lunafast_write_dialogrc() {
	d=$(state_dir)
	mkdir -p "$d" || return 1
	f="$d/dialog.rc"
	export DIALOGRC="$f"
	cat >"$f" <<'LRC'
use_shadow = ON
use_colors = ON
screen_color = (BLACK,WHITE,OFF)
shadow_color = (BLACK,BLACK,ON)
dialog_color = (BLACK,WHITE,OFF)
title_color = (BLUE,WHITE,ON)
border_color = (WHITE,WHITE,ON)
border2_color = (BLACK,WHITE,OFF)
button_active_color = (WHITE,BLUE,ON)
button_inactive_color = (BLACK,WHITE,OFF)
button_key_active_color = button_active_color
button_key_inactive_color = (RED,WHITE,OFF)
button_label_active_color = (YELLOW,BLUE,ON)
button_label_inactive_color = (BLACK,WHITE,OFF)
inputbox_color = dialog_color
inputbox_border_color = border_color
inputbox_border2_color = dialog_color
searchbox_color = dialog_color
searchbox_border_color = border_color
searchbox_border2_color = dialog_color
searchbox_title_color = title_color
menubox_color = dialog_color
menubox_border_color = border_color
menubox_border2_color = dialog_color
item_color = dialog_color
item_selected_color = button_active_color
itemhelp_color = (BLACK,WHITE,OFF)
tag_color = title_color
tag_selected_color = button_label_active_color
tag_key_color = button_key_inactive_color
tag_key_selected_color = (RED,BLUE,ON)
check_color = dialog_color
check_selected_color = button_active_color
uarrow_color = (GREEN,WHITE,ON)
darrow_color = uarrow_color
gauge_color = title_color
position_indicator_color = title_color
form_text_color = dialog_color
form_active_text_color = button_active_color
LRC
}

# Выбор .apk / .xapk: меню найденных + ввод вручную; путь на stdout
dialog_pick_install_package() {
	title=$1
	pf=$(mktemp) || return 1
	collect_install_candidates >"$pf" || true
	if [ ! -s "$pf" ]; then
		rm -f "$pf"
		res=$(dialog --stdout --clear --colors --title "$title" \
			--inputbox "Путь к .apk / .xapk (в каталогах apks/ и . файлов не найдено):" 12 72 "") || return 1
		[ -z "$res" ] && return 1
		ap=$(resolve_installable_path "$res") || {
			dialog --msgbox "Файл не найден: $res" 6 50
			return 1
		}
		printf '%s\n' "$ap"
		return 0
	fi
	n=$(wc -l <"$pf" | tr -d ' ')
	manual=$((n + 1))
	mh=$n
	[ "$mh" -gt 14 ] && mh=14
	tot=$((mh + 9))
	[ "$tot" -gt 26 ] && tot=26
	i=1
	set --
	while read -r pth; do
		[ -z "$pth" ] && continue
		set -- "$@" "$i" "$(basename "$pth")"
		i=$((i + 1))
	done <"$pf"
	set -- "$@" "$manual" "Другой путь…"
	tag=$(dialog --stdout --clear --colors --title "$title" \
		--menu "Список из apks/ и текущего каталога (↑↓, Enter). Пробел не нужен." "$tot" 80 "$mh" "$@") || {
		rm -f "$pf"
		return 1
	}
	tag=$(printf '%s' "$tag" | tr -d '\r\n')
	if [ "$tag" -eq "$manual" ] 2>/dev/null; then
		rm -f "$pf"
		res=$(dialog --stdout --clear --colors --title "$title" \
			--inputbox "Полный путь или имя файла (в т.ч. из apks/):" 11 72 "") || return 1
		[ -z "$res" ] && return 1
		ap=$(resolve_installable_path "$res") || {
			dialog --msgbox "Файл не найден: $res" 6 50
			return 1
		}
		printf '%s\n' "$ap"
		return 0
	fi
	sel=$(sed -n "${tag}p" "$pf")
	rm -f "$pf"
	case "$tag" in *[!0-9]*) return 1 ;; esac
	[ "$tag" -lt 1 ] 2>/dev/null || [ "$tag" -gt "$n" ] 2>/dev/null && return 1
	[ -z "$sel" ] && return 1
	printf '%s\n' "$sel"
}

# Упорядочить APK из распакованного XAPK (base первым)
xapk_ordered_apk_list() {
	root=$1
	out=$2
	: >"$out"
	bf=$(find "$root" -type f \( -iname 'base.apk' -o -iname 'master.apk' \) 2>/dev/null | head -1)
	if [ -n "$bf" ]; then
		printf '%s\n' "$bf" >>"$out"
	fi
	find "$root" -maxdepth 8 -type f -iname '*.apk' 2>/dev/null | sort -u | while read -r L; do
		[ -z "$L" ] && continue
		[ -n "$bf" ] && [ "$L" = "$bf" ] && continue
		printf '%s\n' "$L"
	done >>"$out"
	[ -s "$out" ] || return 1
}

# Установка XAPK (unzip + adb install-multiple при нескольких apk)
install_xapk_to_serials_logged() {
	xapk=$1
	serials_file=$2
	log=$3
	abs=$(apk_abspath "$xapk") || {
		printf '%s\n' "Ошибка: не удалось получить абсолютный путь к XAPK." >>"$log"
		return 1
	}
	if [ ! -f "$abs" ]; then
		printf '%s\n' "Ошибка: файл не найден: $abs" >>"$log"
		return 1
	fi
	command -v unzip >/dev/null 2>&1 || {
		printf '%s\n' "Ошибка: нужен unzip для распаковки .xapk." >>"$log"
		return 1
	}
	td=$(mktemp -d) || return 1
	if ! unzip -q -o "$abs" -d "$td" >>"$log" 2>&1; then
		printf '%s\n' "Ошибка: unzip не смог распаковать архив." >>"$log"
		rm -rf "$td"
		return 1
	fi
	olist=$(mktemp)
	if ! xapk_ordered_apk_list "$td" "$olist"; then
		printf '%s\n' "Ошибка: в XAPK не найдено ни одного .apk." >>"$log"
		rm -rf "$td"
		rm -f "$olist"
		return 1
	fi
	first=$(head -1 "$olist")
	pkg=$(detect_pkg_from_apk "$first")
	napk=$(wc -l <"$olist" | tr -d ' ')
	printf '%s\n' "=== Установка XAPK ===" >>"$log"
	printf '%s\n' "Рабочий каталог: $(pwd)" >>"$log"
	printf '%s\n' "XAPK (абс. путь): $abs" >>"$log"
	printf '%s\n' "Внутри архива APK: $napk шт." >>"$log"
	while read -r L; do printf '%s\n' "  → $L"; done <"$olist" >>"$log"
	if [ -n "$pkg" ]; then
		printf '%s\n' "Пакет (aapt по первому APK): $pkg" >>"$log"
	else
		printf '%s\n' "Пакет: (не определён — aapt/aapt2 для проверки pm)" >>"$log"
	fi
	printf '%s\n' "" >>"$log"

	gm=0
	[ -n "$LUNAFAST_DIALOG_LIVE" ] && lunafast_dialog_has_gauge && gm=1
	err=0
	while read -r raw || [ -n "$raw" ]; do
		s=$(serial_clean "$raw")
		[ -z "$s" ] && continue
		runner=$(mktemp) || {
			rm -f "$olist"
			rm -rf "$td"
			return 1
		}
		export LUNAFAST_S="$s" LUNAFAST_PKG="$pkg"
		if [ "$napk" -eq 1 ]; then
			if [ "$gm" -eq 1 ]; then
				rmt="/data/local/tmp/lunafast_inst_$$.apk"
				{
					printf '%s\n' "########################################"
					printf '%s\n' "# serial: $s (один APK из XAPK)"
					printf '%s\n' "########################################"
				} >>"$log"
				if ! lunafast_dialog_gauge_apk_install "$s" "$first" "$rmt" "$log" "$pkg"; then
					rm -f "$runner"
					err=1
					continue
				fi
				rm -f "$runner"
				continue
			else
				export LUNAFAST_A="$first"
				lunafast_write_runner_single_apk "$runner"
			fi
		else
			export LUNAFAST_OLIST="$olist"
			lunafast_write_runner_install_multiple "$runner"
		fi
		lunafast_stream_runner "$runner" "$log" "[ XAPK → $s ]"
		ec=$?
		rm -f "$runner"
		[ "$ec" -ne 0 ] && err=1
	done <"$serials_file"
	rm -f "$olist"
	rm -rf "$td"
	return "$err"
}

install_installable_to_serials_logged() {
	p=$1
	serials_file=$2
	log=$3
	abs=$(apk_abspath "$p") || {
		printf '%s\n' "Ошибка: путь к файлу." >>"$log"
		return 1
	}
	if is_xapk_path "$abs"; then
		install_xapk_to_serials_logged "$p" "$serials_file" "$log"
	else
		install_apk_to_serials_logged "$p" "$serials_file" "$log"
	fi
}

# Установка на список serial (файл по строкам), лог в $3
install_apk_to_serials_logged() {
	apk=$1
	serials_file=$2
	log=$3
	abs=$(apk_abspath "$apk") || {
		printf '%s\n' "Ошибка: не удалось получить абсолютный путь к APK." >>"$log"
		return 1
	}
	if [ ! -f "$abs" ]; then
		printf '%s\n' "Ошибка: файл не найден: $abs" >>"$log"
		return 1
	fi
	pkg=$(detect_pkg_from_apk "$abs")
	printf '%s\n' "=== Установка ===" >>"$log"
	printf '%s\n' "Рабочий каталог: $(pwd)" >>"$log"
	printf '%s\n' "APK (абс. путь): $abs" >>"$log"
	printf '%s\n' "Размер: $(wc -c <"$abs") байт" >>"$log"
	if [ -n "$pkg" ]; then
		printf '%s\n' "Пакет из APK (aapt): $pkg" >>"$log"
	else
		printf '%s\n' "Пакет из APK: (не определён — установите aapt/aapt2 из Android build-tools для проверки pm)" >>"$log"
	fi
	printf '%s\n' "" >>"$log"

	gm=0
	[ -n "$LUNAFAST_DIALOG_LIVE" ] && lunafast_dialog_has_gauge && gm=1
	err=0
	while read -r raw || [ -n "$raw" ]; do
		s=$(serial_clean "$raw")
		[ -z "$s" ] && continue
		runner=$(mktemp) || return 1
		if [ "$gm" -eq 1 ]; then
			rmt="/data/local/tmp/lunafast_inst_$$.apk"
			{
				printf '%s\n' "########################################"
				printf '%s\n' "# serial: $s"
				printf '%s\n' "########################################"
			} >>"$log"
			if ! lunafast_dialog_gauge_apk_install "$s" "$abs" "$rmt" "$log" "$pkg"; then
				rm -f "$runner"
				err=1
				continue
			fi
			rm -f "$runner"
			continue
		else
			export LUNAFAST_S="$s" LUNAFAST_A="$abs" LUNAFAST_PKG="$pkg"
			lunafast_write_runner_single_apk "$runner"
		fi
		lunafast_stream_runner "$runner" "$log" "[ установка → $s ]"
		ec=$?
		rm -f "$runner"
		[ "$ec" -ne 0 ] && err=1
	done <"$serials_file"
	return "$err"
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
	lunafast_write_dialogrc
	if lunafast_term_tty; then
		lunafast_term_blue_fill
		trap 'lunafast_term_restore; clear; trap - INT; exit 130' INT
	fi
	export LUNAFAST_DIALOG_LIVE=1
	ensure_adb
	[ -n "$CONNECT_LIST" ] && connect_explicit_list
	while true; do
		load_settings
		mddef=${LUNAFAST_MENU_DEFAULT_ITEM:-1}
		unset LUNAFAST_MENU_DEFAULT_ITEM
		c=$(dialog --stdout --clear --colors \
			--default-item "$mddef" \
			--title "[ lunafast-fw-upload ] ─ Главное меню" \
			--menu "Порт: $ADB_PORT  │  Подсеть: ${SCAN_SUBNET}.x\nЖурнал: lunafast_install.log (новые записи в начале файла) · п.5\n\n↑↓ выбор, Enter — открыть раздел." 23 80 7 \
			1 "Сеть › поиск устройств (скан LAN)" \
			2 "Прошивка › вложенное меню (цели, APK/XAPK…)" \
			3 "Настройки" \
			4 "Просмотр: adb devices -l" \
			5 "Журнал установок (сверху — последняя операция)" \
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
		5) dialog_show_project_log ;;
		0) break ;;
		esac
	done
	trap - INT 2>/dev/null
	unset LUNAFAST_DIALOG_LIVE
	lunafast_term_restore
	clear
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
			--menu "Иерархия: Главная › Прошивка\n\nп.2 — только отметить устройства (Пробел в checklist)." 19 76 7 \
			1 "Подключить вручную: IP:PORT" \
			2 "Выбор устройств для прошивки (checklist → сохранить)" \
			3 "Установить APK / XAPK на сохранённый список (после п.2)" \
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
	dialog --msgbox "Сохранено устройств: $nc\nДалее: п.3 — установка APK/XAPK на этот список." 8 65
}

dialog_show_saved() {
	f=$(selected_targets_file)
	if [ ! -s "$f" ]; then
		dialog --msgbox "Список целей пуст. Используйте п.2." 6 50
		return
	fi
	dialog --title "[ сохранённые serial ]" --textbox "$f" 16 72
}

dialog_show_project_log() {
	lg=$(lunafast_project_log_path)
	if [ ! -s "$lg" ]; then
		dialog --msgbox "Журнал пуст или ещё не создавался.\n\nФайл:\n$lg" 11 72
		return
	fi
	dialog --title "[ журнал установок ]" --textbox "$lg" 32 94
}

dialog_install_saved() {
	f=$(selected_targets_file)
	if [ ! -s "$f" ]; then
		dialog --msgbox "Сначала: Прошивка › п.2 — выбор устройств." 7 55
		return
	fi
	ap=$(dialog_pick_install_package "[ APK / XAPK ]") || return
	dialog --yesno "Установить выбранный пакет на отмеченные устройства?" 7 65 || return
	rep=$(mktemp) || {
		dialog --msgbox "Не удалось создать временный файл журнала." 6 60
		return 1
	}
	if ! lunafast_begin_log_section "$rep" "Установка: $(basename "$ap") · $ap"; then
		rm -f "$rep"
		dialog --msgbox "Не удалось записать журнал (сессия)." 8 72
		return 1
	fi
	install_installable_to_serials_logged "$ap" "$f" "$rep"
	ret=$?
	lunafast_end_log_section "$rep" "$ret"
	lunafast_prepend_session_to_project_log "$rep" || true
	proj=$(lunafast_project_log_path)
	dialog --title "[ журнал · сверху последняя операция ]" --textbox "$proj" 28 92
	if [ "$ret" -ne 0 ]; then
		dialog --msgbox "Код возврата: $ret (есть ошибки).\n\nПолный журнал:\n$proj\n\nПросмотр: главное меню · п.5." 14 72
	fi
}

dialog_install_wizard() {
	load_settings
	ensure_adb
	addr=$(dialog --stdout --title "[ Мастер ]" --inputbox "ADB IP:PORT [пусто — пропуск]:" 10 70 "") || return
	if [ -n "$addr" ] && is_adb_target "$addr"; then
		adb connect "$addr" || true
	fi
	ap=$(dialog_pick_install_package "[ Мастер › пакет ]") || return
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
		--checklist "Отметьте устройства (выбранный пакет — в предыдущем шаге)." "$h" 78 "$lh" $args) || {
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
	rep=$(mktemp) || {
		rm -f "$p"
		dialog --msgbox "Не удалось создать временный файл журнала." 6 60
		return 1
	}
	if ! lunafast_begin_log_section "$rep" "Мастер: $(basename "$ap") · $ap"; then
		rm -f "$rep" "$p"
		dialog --msgbox "Не удалось записать журнал (сессия)." 8 72
		return 1
	fi
	install_installable_to_serials_logged "$ap" "$p" "$rep"
	ret=$?
	lunafast_end_log_section "$rep" "$ret"
	lunafast_prepend_session_to_project_log "$rep" || true
	proj=$(lunafast_project_log_path)
	dialog --title "[ журнал · сверху последняя операция ]" --textbox "$proj" 28 92
	rm -f "$p"
	if [ "$ret" -ne 0 ]; then
		dialog --msgbox "Есть ошибки установки (код $ret).\n\nПолный журнал:\n$proj\n\nГлавное меню · п.5." 14 72
	fi
}

dialog_settings() {
	load_settings
	p=$(dialog --stdout --inputbox "Порт ADB:" 8 60 "$ADB_PORT") || return
	[ -n "$p" ] && ADB_PORT=$p
	s=$(dialog --stdout --inputbox "Подсеть (3 октета):" 8 60 "$SCAN_SUBNET") || return
	[ -n "$s" ] && SCAN_SUBNET=$s
	save_settings
	LUNAFAST_MENU_DEFAULT_ITEM=3
	export LUNAFAST_MENU_DEFAULT_ITEM
	dialog --msgbox "Сохранено в $(settings_file)\n\nСкан подсети не запускается.\nПоиск в LAN — отдельно, пункт «Сеть › поиск…» в меню." 10 62
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
		printf '│  2) Выбор устройств → файл (для п.3)                     │\n'
		printf '│  3) Установить APK/XAPK на сохранённый список            │\n'
		printf '│  4) Мастер (connect → пакет → номера)                    │\n'
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
	cand=$(collect_install_candidates)
	if [ -n "$cand" ]; then
		printf '%s\n' "--- найдены APK/XAPK (apks/, текущий каталог) ---"
		printf '%s\n' "$cand"
		printf '%s\n' "--------------------------------------------------"
	fi
	printf '%s' "Путь или имя файла [из списка / apks/]: "
	read -r path || return
	[ -z "$path" ] && return
	ap=$(resolve_installable_path "$path") || {
		printf '%s\n' "Нет файла: $path"
		read -r _
		return
	}
	lg=$(mktemp) || {
		printf '%s\n' "Не удалось создать временный файл журнала."
		read -r _
		return
	}
	lunafast_begin_log_section "$lg" "Установка: $(basename "$ap") · $ap" || {
		rm -f "$lg"
		printf '%s\n' "Не удалось начать запись сессии."
		read -r _
		return
	}
	install_installable_to_serials_logged "$ap" "$f" "$lg"
	ret=$?
	lunafast_end_log_section "$lg" "$ret"
	lunafast_prepend_session_to_project_log "$lg" || true
	proj=$(lunafast_project_log_path)
	printf '%s\n' "--- начало файла $proj (сверху — самая свежая запись) ---"
	head -n 120 "$proj"
	printf '%s\n' "--- конец, Enter ---"
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
	cand=$(collect_install_candidates)
	if [ -n "$cand" ]; then
		printf '%s\n' "--- APK/XAPK рядом со скриптом ---"
		printf '%s\n' "$cand"
		printf '%s\n' "----------------------------------"
	fi
	printf '%s' "Путь или имя [apks/…]: "
	read -r apk || {
		rm -f "$sf" "$p"
		return
	}
	[ -z "$apk" ] && {
		rm -f "$sf" "$p"
		return
	}
	ap=$(resolve_installable_path "$apk") || {
		rm -f "$sf" "$p"
		read -r _
		return
	}
	print_numbered_txt "$sf"
	printf '%s' "Номера устройств [Enter=all]: "
	read -r pick
	pick_serials_to_file "$sf" "$pick" "$p" || {
		rm -f "$sf" "$p"
		read -r _
		return
	}
	rm -f "$sf"
	lg=$(mktemp) || {
		rm -f "$p"
		printf '%s\n' "Не удалось создать временный файл журнала."
		read -r _
		return
	}
	lunafast_begin_log_section "$lg" "Установка: $(basename "$ap") · $ap" || {
		rm -f "$lg" "$p"
		printf '%s\n' "Не удалось начать запись сессии."
		read -r _
		return
	}
	install_installable_to_serials_logged "$ap" "$p" "$lg"
	ret=$?
	lunafast_end_log_section "$lg" "$ret"
	lunafast_prepend_session_to_project_log "$lg" || true
	rm -f "$p"
	proj=$(lunafast_project_log_path)
	printf '%s\n' "--- начало $proj (сверху — свежая запись), код $ret ---"
	head -n 120 "$proj"
	printf '%s\n' "--- Enter ---"
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
		printf '│  5) Журнал установок (lunafast_install.log)             │\n'
		printf '│  0) Выход                                              │\n'
		text_hline_bot 58
		adb devices -l
		printf '%s' "[0-5]: "
		read -r c || exit 0
		case "$c" in
		1) text_search_flow ;;
		2) text_flash_menu_txt ;;
		3) menu_settings_text ;;
		4) ;;
		5)
			_tlg=$(lunafast_project_log_path)
			if [ ! -s "$_tlg" ]; then
				printf '%s\n' "Журнал пуст: $_tlg"
			else
				if [ -n "${PAGER:-}" ]; then
					$PAGER "$_tlg"
				elif command -v less >/dev/null 2>&1; then
					less -S "$_tlg"
				elif command -v more >/dev/null 2>&1; then
					more "$_tlg"
				else
					cat "$_tlg"
				fi
			fi
			read -r _
			;;
		0) exit 0 ;;
		esac
	done
}

install_apk_batch() {
	[ -f "$1" ] || exit 1
	load_settings
	ensure_adb
	[ -n "$CONNECT_LIST" ] && connect_explicit_list
	listf=$(mktemp)
	adb_device_serials >"$listf"
	if [ ! -s "$listf" ]; then
		rm -f "$listf"
		printf '%s\n' "Нет device." >&2
		exit 1
	fi
	lg=$(mktemp) || exit 1
	lunafast_begin_log_section "$lg" "CLI batch: $(basename "$1") · $1" || exit 1
	install_installable_to_serials_logged "$1" "$listf" "$lg"
	ret=$?
	lunafast_end_log_section "$lg" "$ret"
	lunafast_prepend_session_to_project_log "$lg" || true
	proj=$(lunafast_project_log_path)
	printf '%s\n' "--- начало журнала $proj (сверху — эта установка) ---"
	head -n 200 "$proj"
	rm -f "$listf"
	exit "$ret"
}

# Без ADB/планшетов: быстрая проверка после правок UI
lunafast_selftest() {
	s=$1
	st=0
	printf '%s' '[1] sh -n … '
	sh -n "$s" || {
		printf 'FAIL\n'
		return 1
	}
	printf 'OK\n'

	printf '%s' '[2] dialog + dialog.rc … '
	if ! command -v dialog >/dev/null 2>&1; then
		printf 'SKIP (нет dialog)\n'
		return 0
	fi
	_th=$(mktemp -d) || return 1
	HOME=$_th
	export HOME
	if lunafast_write_dialogrc && DIALOGRC="$HOME/.lunafast_fw_upload/dialog.rc" dialog --print-maxsize >/dev/null 2>&1; then
		printf 'OK\n'
	else
		printf 'FAIL (rc или dialog)\n'
		st=1
	fi
	rm -rf "$_th"

	printf '%s' '[3] виджеты … '
	dialog --help 2>&1 | grep -q '\-\-prgbox' && pg=1 || pg=0
	dialog --help 2>&1 | grep -q tailboxbg && tb=1 || tb=0
	dialog --help 2>&1 | grep -q '\-\-gauge' && gg=1 || gg=0
	printf 'prgbox=%s tailboxbg=%s gauge=%s\n' "$pg" "$tb" "$gg"
	if [ "$gg" != 1 ]; then
		printf '%s\n' '    предупреждение: нет --gauge — шкала отправки не покажется'
	fi
	if [ "$pg" != 1 ]; then
		printf '%s\n' '    предупреждение: без --prgbox хуже поток pm install'
	fi

	printf '%s' '[4] нормализация \\r … '
	_nl=$(printf 'a\rb\n' | tr '\r' '\n' | wc -l | tr -d ' ')
	if [ "$_nl" != 2 ]; then
		printf 'FAIL (строк=%s)\n' "$_nl"
		return 1
	fi
	printf 'OK\n'

	return "$st"
}

# ═══ entry ═══
if [ "${1:-}" = "--selftest" ]; then
	lunafast_selftest "$0"
	exit $?
fi

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
