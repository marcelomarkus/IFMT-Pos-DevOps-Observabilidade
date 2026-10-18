#!/bin/sh
# Verificacao da stack de observabilidade: checa a saude de cada servico e
# mostra a quantidade de telemetria ja armazenada.
#
# Uso: ./scripts/check-stack.sh
# Variaveis: GRAFANA_URL, PROMETHEUS_URL, LOKI_URL, TEMPO_URL, API_URL

set -u

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"
TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"
API_URL="${API_URL:-http://localhost:8000}"

code() { # code URL [metodo]
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X "${2:-GET}" "$1" 2>/dev/null || echo 000
}

line() { # line ROTULO VALOR
  printf '  %-34s %s\n' "$1" "$2"
}

echo "== Saude dos servicos =="
line "Grafana /api/health"        "$(code "$GRAFANA_URL/api/health")"
line "Prometheus /-/healthy"      "$(code "$PROMETHEUS_URL/-/healthy")"
line "Loki /loki/api/v1/labels"    "$(code "$LOKI_URL/loki/api/v1/labels")"
line "Tempo /ready"               "$(code "$TEMPO_URL/ready")"
line "ShopFlow API /healthz"      "$(code "$API_URL/healthz")"

echo
echo "== Metricas no Prometheus =="
metricas=$(curl -s --max-time 10 "$PROMETHEUS_URL/api/v1/label/__name__/values" \
  | tr ',' '\n' | tr -d '"[] ' | grep -c '^shopflow\|^http_server\|^host_cpu\|^traces_' || true)
line "series shopflow/http/host/traces" "$metricas"

for m in shopflow_orders_completed_total shopflow_checkout_duration_milliseconds_count; do
  valor=$(curl -s --max-time 10 "$PROMETHEUS_URL/api/v1/query?query=sum($m)" \
    | sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p')
  line "$m" "${valor:-(sem dados)}"
done

echo
echo "== Logs no Loki =="
logs=$(curl -s --max-time 10 --get --data-urlencode 'query=sum(count_over_time({service_name="shopflow-api"}[1h]))' \
  "$LOKI_URL/loki/api/v1/query" | sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p')
line "linhas de log (1h, shopflow-api)" "${logs:-(sem dados)}"

echo
echo "== Traces no Tempo =="
traces=$(curl -s --max-time 10 "$TEMPO_URL/api/search?limit=20" | grep -o '"traceID"' | wc -l)
line "traces recentes (limite 20)" "$traces"

echo
echo "Dashboards provisionados:"
curl -s --max-time 10 "$GRAFANA_URL/api/search?type=dash-db" \
  | grep -o '"title":"[^"]*"' | sed 's/"title":"/  - /; s/"$//' || echo "  (nenhum)"

echo
echo "Uso rapido:"
echo "  http://localhost:3000/d/shopflow-observability   -> dashboard"
echo "  http://localhost:9090/targets                    -> alvos do Prometheus"
echo "  http://localhost:3000/explore                    -> consultar logs/traces"
