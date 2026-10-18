#!/bin/sh
# Salva evidencias textuais da stack em execucao dentro de evidencias/.
# Complementa os prints do Grafana/Prometheus: cada arquivo corresponde a uma
# verificacao exigida na atividade (metricas, logs, traces, load test, collector).
#
# Uso: ./scripts/coletar-evidencias.sh
# Requer: curl (obrigatorio) e python3 (opcional, apenas para o resumo dos paineis).

set -u

BASE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$BASE/evidencias"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"
TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"
API_URL="${API_URL:-http://localhost:8000}"

mkdir -p "$OUT"
echo "Salvando evidencias em $OUT"

# 1. Containers em execucao (prova da orquestracao).
podman ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' > "$OUT/01-containers.txt" 2>&1

# 2. Recursos gerenciados pelo Terraform.
(cd "$BASE" && terraform output) > "$OUT/02-terraform-output.txt" 2>&1
(cd "$BASE" && terraform state list) > "$OUT/03-terraform-state.txt" 2>&1

# 3. Saude dos servicos e volume de telemetria.
"$BASE/scripts/check-stack.sh" > "$OUT/04-saude-e-telemetria.txt" 2>&1

# 4. Catalogo de metricas (nomes das series no Prometheus).
curl -s --max-time 10 "$PROMETHEUS_URL/api/v1/label/__name__/values" \
  | tr ',' '\n' | tr -d '"[] ' | grep -E '^(shopflow|http_server|system_|traces_)' | sort \
  > "$OUT/05-metricas-prometheus.txt" 2>&1

# 5. Alvos monitorados pelo Prometheus (UP/DOWN).
curl -s --max-time 10 "$PROMETHEUS_URL/api/v1/targets?state=active" \
  | tr '{' '\n' | grep -oE '"job":"[^"]*"|"health":"[^"]*"|"scrapeUrl":"[^"]*"' \
  > "$OUT/06-alvos-prometheus.txt" 2>&1

# 6. Consulta instantanea das principais metricas de negocio.
{
  for m in shopflow_availability_ratio \
           shopflow_orders_completed_total \
           shopflow_orders_failed_total \
           shopflow_auth_failures_total \
           shopflow_payment_queue_size_ratio; do
    printf '%-42s ' "$m"
    curl -s --max-time 10 --get --data-urlencode "query=sum($m)" "$PROMETHEUS_URL/api/v1/query" \
      | sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p'
    echo
  done
  printf '%-42s ' "taxa de erro 5xx (%)"
  curl -s --max-time 10 --get --data-urlencode \
    'query=100 * sum(rate(http_server_duration_milliseconds_count{service_name="shopflow-api",http_status_code=~"5.."}[5m])) / clamp_min(sum(rate(http_server_duration_milliseconds_count{service_name="shopflow-api"}[5m])), 0.001)' \
    "$PROMETHEUS_URL/api/v1/query" | sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p'
  echo
  printf '%-42s ' "latencia p95 (ms)"
  curl -s --max-time 10 --get --data-urlencode \
    'query=histogram_quantile(0.95, sum by (le) (rate(http_server_duration_milliseconds_bucket{service_name="shopflow-api"}[5m])))' \
    "$PROMETHEUS_URL/api/v1/query" | sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p'
  echo
} > "$OUT/07-metricas-negocio.txt" 2>&1

# 7. Logs estruturados no Loki (ultimas linhas + contagem).
curl -s --max-time 10 --get --data-urlencode 'query={service_name="shopflow-api"}' \
  --data-urlencode 'limit=15' --data-urlencode 'direction=backward' \
  "$LOKI_URL/loki/api/v1/query_range" > "$OUT/08-logs-loki.json" 2>&1
curl -s --max-time 10 --get --data-urlencode 'query=sum(count_over_time({service_name="shopflow-api"}[1h]))' \
  "$LOKI_URL/loki/api/v1/query" > "$OUT/09-logs-loki-contagem.json" 2>&1

# 8. Traces no Tempo (busca TraceQL + contagem).
curl -s --max-time 15 --get --data-urlencode 'q={ resource.service.name = "shopflow-api" }' \
  --data-urlencode 'limit=20' "$TEMPO_URL/api/search" > "$OUT/10-traces-tempo.json" 2>&1

# 9. Logs dos containers (aplicacao, gerador de carga e collector).
podman logs --tail 25 shopflow-api > "$OUT/11-logs-api.txt" 2>&1
podman logs --tail 25 loadgen > "$OUT/12-logs-loadgen.txt" 2>&1
podman logs --tail 40 otel-collector > "$OUT/13-logs-collector.txt" 2>&1

# 10. Valores atuais de cada painel do dashboard (opcional: usa python3).
if command -v python3 >/dev/null 2>&1; then
  python3 - "$BASE/configs/grafana/dashboards/shopflow.json" "$PROMETHEUS_URL" > "$OUT/14-paineis-valores.txt" 2>&1 <<'PY'
import json, sys, urllib.parse, urllib.request
dashboard, prometheus = sys.argv[1], sys.argv[2]
d = json.load(open(dashboard))
print(f"Dashboard: {d['title']} (uid={d['uid']})\n")
for panel in d['panels']:
    if panel.get('type') in ('row', 'traces', 'logs'):
        continue
    for target in panel.get('targets', []):
        url = f"{prometheus}/api/v1/query?query={urllib.parse.quote(target['expr'])}"
        try:
            with urllib.request.urlopen(url, timeout=15) as response:
                result = json.load(response)['data']['result']
            value = result[0]['value'][1] if result and 'value' in result[0] else 'sem dados'
        except Exception as error:
            value = f"erro: {error}"
        print(f"[{panel['id']:>2}] {panel['title']:<48} {value}")
PY
fi

# 11. Encerramento: como os prints foram produzidos.
{
  echo "Comandos para reproduzir as evidencias:"
  echo "  export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock"
  echo "  terraform apply -auto-approve       # sobe a stack"
  echo "  ./scripts/load-test.sh              # (opcional) carga no host"
  echo "  ./scripts/fault-injection.sh down   # simula indisponibilidade"
  echo "  ./scripts/fault-injection.sh up     # restabelece"
  echo "  ./scripts/check-stack.sh            # saude + telemetria"
  echo "  ./scripts/coletar-evidencias.sh     # regera esta pasta"
} > "$OUT/00-como-reproduzir.txt" 2>&1

ls -1 "$OUT"
echo
echo "Pronto. Para os prints, abra http://localhost:3000/d/shopflow-observability"
