#!/usr/bin/env bash
# Verifier helpers: меню — регистрация без БО, получение ЦП, выдача согласия

set -uo pipefail

TRACE_ID="${TRACE_ID:-69dbdf9a}"
VERIFIER_X_API_KEY="${VERIFIER_X_API_KEY:-demo}"
VERIFIER_HOST="${VERIFIER_HOST:-localhost}"
VERIFIER_PORT="${VERIFIER_PORT:-9300}"
OID="${OID:-}"

BASE_URL="http://${VERIFIER_HOST}:${VERIFIER_PORT}"

ask_oid() {
  local current="${OID}"
  local input=""

  if [[ -n "${current}" ]]; then
    read -r -p "OID [${current}]: " input
  else
    read -r -p "OID: " input
  fi

  if [[ -n "${input}" ]]; then
    OID="${input}"
  fi

  if [[ -z "${OID}" ]]; then
    echo "OID не задан." >&2
    return 1
  fi
}

registration_without_bo() {
  local oid="${1:-$OID}"
  OID="$oid"

  curl -sS -X POST \
    "${BASE_URL}/api/v1/registration" \
    --header "trace-id: ${TRACE_ID}" \
    --header "accept: application/json" \
    --header "X-API-KEY: ${VERIFIER_X_API_KEY}" \
    --header "Content-Type: application/json" \
    --data "{\"user_id\": \"${oid}\"}"

  echo
  echo "Проверь логи MATCHING:"
  echo "  Person was matching ... userId: ${oid}   # МА"
  echo "  Person was not matching ... userId: ${oid} # МF"
}

get_client_info() {
  local oid="${1:-$OID}"
  OID="$oid"

  curl -sS -X POST \
    "${BASE_URL}/api/v1/client-info" \
    --header "trace-id: ${TRACE_ID}" \
    --header "accept: application/json" \
    --header "X-API-KEY: ${VERIFIER_X_API_KEY}" \
    --header "Content-Type: application/json" \
    --data "{\"oid\": \"${oid}\"}"

  echo
}

generate_consent() {
  local oid="${1:-$OID}"
  OID="$oid"

  curl -sS --location \
    "${BASE_URL}/api/v1/generate-consent" \
    --header "trace-id: ${TRACE_ID}" \
    --header "Content-Type: application/json" \
    --header "X-API-KEY: ${VERIFIER_X_API_KEY}" \
    --data "{\"oid\": \"${oid}\"}"

  echo
}

print_menu() {
  cat <<EOF

==============================
 Verifier  ${VERIFIER_HOST}:${VERIFIER_PORT}
 TRACE_ID=${TRACE_ID}  OID=${OID:-<не задан>}
==============================
  1) Регистрация без БО
  2) Получение ЦП
  3) Выдача согласия
  0) Выход   (также: q / exit / quit)
==============================
EOF
}

run_menu() {
  local choice=""

  while true; do
    print_menu
    read -r -p "Выбор: " choice
    choice="$(printf '%s' "${choice}" | tr '[:upper:]' '[:lower:]')"
    choice="${choice#"${choice%%[![:space:]]*}"}"
    choice="${choice%"${choice##*[![:space:]]}"}"

    case "${choice}" in
      1)
        ask_oid || continue
        echo
        registration_without_bo "${OID}" || echo "Ошибка запроса." >&2
        ;;
      2)
        ask_oid || continue
        echo
        get_client_info "${OID}" || echo "Ошибка запроса." >&2
        ;;
      3)
        ask_oid || continue
        echo
        generate_consent "${OID}" || echo "Ошибка запроса." >&2
        ;;
      0|q|exit|quit)
        echo "Выход."
        break
        ;;
      "")
        continue
        ;;
      *)
        echo "Неизвестная команда: ${choice}"
        echo "Введите 1, 2, 3 или 0 (exit) для выхода."
        ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_menu
fi
