#!/bin/sh
# Injecao de falhas na ShopFlow API - usado para gerar evidencias de
# indisponibilidade, taxa de erro e correlacao de alertas.
#
# Uso:
#   ./scripts/fault-injection.sh down    # simula indisponibilidade (HTTP 503)
#   ./scripts/fault-injection.sh up      # restabelece o servico
#   ./scripts/fault-injection.sh status  # consulta o estado atual
#
# Variaveis: API_URL (padrao http://localhost:8000)

set -u

API_URL="${API_URL:-http://localhost:8000}"
action="${1:-status}"

case "$action" in
  down)
    printf 'injetando indisponibilidade... '
    curl -s -X POST "$API_URL/chaos/down"
    echo
    echo "A API respondera 503 ate a execucao de 'fault-injection.sh up'."
    ;;
  up)
    printf 'restabelecendo servico... '
    curl -s -X POST "$API_URL/chaos/up"
    echo
    ;;
  status)
    printf 'GET /healthz -> '
    curl -s -o /dev/null -w '%{http_code}\n' "$API_URL/healthz"
    ;;
  *)
    echo "acao invalida: $action (use down, up ou status)" >&2
    exit 1
    ;;
esac
