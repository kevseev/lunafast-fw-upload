#!/usr/bin/env bash
# Verifier helpers: меню — регистрация без БО, получение ЦП, выдача согласия

set -uo pipefail

TRACE_ID="${TRACE_ID:-69dbdf9a}"
VERIFIER_X_API_KEY="${VERIFIER_X_API_KEY:-demo}"
VERIFIER_HOST="${VERIFIER_HOST:-localhost}"
VERIFIER_PORT="${VERIFIER_PORT:-9300}"
OID="${OID:-}"
VERIFIER_CONTAINER="${VERIFIER_CONTAINER:-verifier-verifier-1-1}"
REG_LOG_WAIT_SEC="${REG_LOG_WAIT_SEC:-60}"
REG_LOG_POLL_SEC="${REG_LOG_POLL_SEC:-2}"
REG_LOG_TAIL="${REG_LOG_TAIL:-500}"

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

# Ищем в docker logs callback регистрации для oid.
# Пример:
#   Registration callback parsed: success=True, status=MA, person_id=None, oid=239846666
wait_registration_result() {
  local oid="$1"
  local deadline=$((SECONDS + REG_LOG_WAIT_SEC))
  local line=""
  local status=""

  echo "Жду Registration callback в логах ${VERIFIER_CONTAINER} (до ${REG_LOG_WAIT_SEC}с)..."

  while (( SECONDS < deadline )); do
    line="$(
      docker logs -n "${REG_LOG_TAIL}" "${VERIFIER_CONTAINER}" 2>&1 \
        | grep "Registration callback parsed:" \
        | grep "oid=${oid}" \
        | tail -n 1 || true
    )"

    if [[ -n "${line}" ]]; then
      echo
      echo "Лог:"
      echo "  ${line}"

      status="$(
        printf '%s' "${line}" \
          | sed -n 's/.*status=\([^,[:space:]]*\).*/\1/p'
      )"

      case "${status}" in
        MA)
          echo "Результат: МА — персона есть (matching)."
          return 0
          ;;
        MF)
          echo "Результат: МF — персоны нет (not matching)."
          return 0
          ;;
        *)
          echo "Результат: status=${status:-?} (не разобрал MA/MF)."
          return 0
          ;;
      esac
    fi

    sleep "${REG_LOG_POLL_SEC}"
  done

  echo "Таймаут: callback для oid=${oid} не найден в ${VERIFIER_CONTAINER}." >&2
  echo "Проверь вручную:" >&2
  echo "  docker logs -n ${REG_LOG_TAIL} ${VERIFIER_CONTAINER} 2>&1 | grep ${oid}" >&2
  return 1
}

registration_without_bo() {
  local oid="${1:-$OID}"
  OID="$oid"
  local http_body=""

  http_body="$(
    curl -sS -X POST \
      "${BASE_URL}/api/v1/registration" \
      --header "trace-id: ${TRACE_ID}" \
      --header "accept: application/json" \
      --header "X-API-KEY: ${VERIFIER_X_API_KEY}" \
      --header "Content-Type: application/json" \
      --data "{\"user_id\": \"${oid}\"}"
  )"

  echo "${http_body}"
  echo
  wait_registration_result "${oid}"
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
  # oid и redirect_url — заглушки для валидации тела запроса
  local oid="${CONSENT_OID_STUB:-1000723725}"
  local redirect_url="${CONSENT_REDIRECT_URL:-https://visionlabs.ru}"

  curl -sS --location \
    "${BASE_URL}/api/v1/generate-consent" \
    --header "trace-id: ${TRACE_ID}" \
    --header "Content-Type: application/json" \
    --header "X-API-KEY: ${VERIFIER_X_API_KEY}" \
    --data "{\"oid\": \"${oid}\", \"redirect_url\": \"${redirect_url}\"}"

  echo
}

print_menu() {
  cat <<EOF

==============================
 Verifier  ${VERIFIER_HOST}:${VERIFIER_PORT}
 TRACE_ID=${TRACE_ID}  OID=${OID:-<не задан>}
 container=${VERIFIER_CONTAINER}
==============================
  1) Регистрация без БО (+ проверка логов)
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
        registration_without_bo "${OID}" || echo "Ошибка регистрации / проверки логов." >&2
        ;;
      2)
        ask_oid || continue
        echo
        get_client_info "${OID}" || echo "Ошибка запроса." >&2
        ;;
      3)
        echo
        generate_consent || echo "Ошибка запроса." >&2
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
