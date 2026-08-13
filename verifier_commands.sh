#!/usr/bin/env bash
# Verifier helpers: регистрация без БО, получение ЦП, выдача согласия

set -euo pipefail

TRACE_ID="${TRACE_ID:-69dbdf9a}"
VERIFIER_X_API_KEY="${VERIFIER_X_API_KEY:-demo}"
VERIFIER_HOST="${VERIFIER_HOST:-localhost}"
VERIFIER_PORT="${VERIFIER_PORT:-9300}"
OID="${OID:-}"

BASE_URL="http://${VERIFIER_HOST}:${VERIFIER_PORT}"

_require_oid() {
  if [[ -z "${OID}" ]]; then
    echo "OID is empty. Set OID env var or pass it as an argument." >&2
    return 1
  fi
}

# 1) Регистрация без БО
# Usage: registration_without_bo [oid]
registration_without_bo() {
  local oid="${1:-$OID}"
  OID="$oid"
  _require_oid

  curl -sS -X POST \
    "${BASE_URL}/api/v1/registration" \
    --header "trace-id: ${TRACE_ID}" \
    --header "accept: application/json" \
    --header "X-API-KEY: ${VERIFIER_X_API_KEY}" \
    --header "Content-Type: application/json" \
    --data "{\"user_id\": \"${oid}\"}"

  echo
  echo "Check MATCHING logs for:"
  echo "  Person was matching ... userId: ${oid}   # МА"
  echo "  Person was not matching ... userId: ${oid} # МF"
}

# 2) Получение ЦП (client-info)
# Usage: get_client_info [oid]
get_client_info() {
  local oid="${1:-$OID}"
  OID="$oid"
  _require_oid

  curl -sS -X POST \
    "${BASE_URL}/api/v1/client-info" \
    --header "trace-id: ${TRACE_ID}" \
    --header "accept: application/json" \
    --header "X-API-KEY: ${VERIFIER_X_API_KEY}" \
    --header "Content-Type: application/json" \
    --data "{\"oid\": \"${oid}\"}"

  echo
}

# 3) Выдача согласия (IDENTIFICATION_EBS_AERO)
# Usage: generate_consent [oid]
generate_consent() {
  local oid="${1:-$OID}"
  OID="$oid"
  _require_oid

  curl -sS --location \
    "${BASE_URL}/api/v1/generate-consent" \
    --header "trace-id: ${TRACE_ID}" \
    --header "Content-Type: application/json" \
    --header "X-API-KEY: ${VERIFIER_X_API_KEY}" \
    --data "{\"oid\": \"${oid}\"}"

  echo
}

usage() {
  cat <<EOF
Usage:
  OID=<oid> $0 registration_without_bo
  OID=<oid> $0 get_client_info
  OID=<oid> $0 generate_consent

  # or with oid as argument:
  $0 registration_without_bo <oid>
  $0 get_client_info <oid>
  $0 generate_consent <oid>

Env (defaults from verifier docs):
  TRACE_ID=${TRACE_ID}
  VERIFIER_X_API_KEY=${VERIFIER_X_API_KEY}
  VERIFIER_HOST=${VERIFIER_HOST}
  VERIFIER_PORT=${VERIFIER_PORT}
  OID=${OID}
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    registration_without_bo) registration_without_bo "$@" ;;
    get_client_info) get_client_info "$@" ;;
    generate_consent) generate_consent "$@" ;;
    ""|-h|--help|help) usage ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
fi
