#!/bin/sh
# Gera os prints (PNG) das telas do Grafana e do Prometheus usando o Chrome headless.
# Os arquivos vao para evidencias/prints/.
#
# Uso: ./scripts/capturar-prints.sh
# Variaveis: CHROME (padrao google-chrome), LARGURA, ESCALA, DASH_URL, PROMETHEUS_URL
#
# Requer: Google Chrome (ou Chromium) instalado e a stack em execucao.

set -u

BASE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$BASE/evidencias/prints"
CHROME="${CHROME:-google-chrome}"
LARGURA="${LARGURA:-1600}"
ESCALA="${ESCALA:-1.5}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
DASH_URL="${DASH_URL:-$GRAFANA_URL/d/shopflow-observability/shopflow-observabilidade}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
API_URL="${API_URL:-http://localhost:8000}"

PERIODO="from=now-15m&to=now&refresh=off"
PAINEL="$DASH_URL?viewPanel=%s&kiosk&$PERIODO"

mkdir -p "$OUT"
echo "Salvando prints em $OUT"

print_de() { # print_de ARQUIVO ALTURA URL
  arquivo="$1"
  altura="$2"
  url="$3"
  "$CHROME" --headless=new --disable-gpu --no-sandbox --hide-scrollbars \
    --force-device-scale-factor="$ESCALA" --window-size="$LARGURA,$altura" \
    --virtual-time-budget=20000 --screenshot="$OUT/$arquivo" "$url" >/dev/null 2>&1
  if [ -s "$OUT/$arquivo" ]; then
    printf '  %-42s ok\n' "$arquivo"
  else
    printf '  %-42s FALHOU\n' "$arquivo"
  fi
}

echo "-- dashboard (visao completa)"
print_de 01-dashboard-completo.png 2900 "$DASH_URL?kiosk&$PERIODO"

echo "-- secoes 1 e 2 (metricas RED e de negocio)"
print_de 02-red-disponibilidade.png 700 "$(printf "$PAINEL" 2)"
print_de 03-red-erro-latencia.png 700 "$(printf "$PAINEL" 4)"
print_de 04-trafego-por-rota.png 800 "$(printf "$PAINEL" 6)"
print_de 05-latencia-da-api.png 800 "$(printf "$PAINEL" 7)"
print_de 06-pedidos-concluidos-x-falhos.png 700 "$(printf "$PAINEL" 11)"
print_de 07-pagamento-latencia-e-fila.png 800 "$(printf "$PAINEL" 12)"
print_de 08-operacoes-rastreadas.png 800 "$(printf "$PAINEL" 13)"

echo "-- secao 3 (infraestrutura do host)"
print_de 09-host-cpu.png 800 "$(printf "$PAINEL" 15)"
print_de 10-host-memoria.png 800 "$(printf "$PAINEL" 16)"
print_de 11-host-disco.png 800 "$(printf "$PAINEL" 17)"
print_de 12-host-rede.png 800 "$(printf "$PAINEL" 18)"

echo "-- secao 4 (traces e logs)"
print_de 13-traces-tempo.png 800 "$(printf "$PAINEL" 20)"
print_de 14-logs-loki.png 800 "$(printf "$PAINEL" 21)"

echo "-- Prometheus"
print_de 15-prometheus-alvos.png 1000 "$PROMETHEUS_URL/targets"
# O grafico nativo do Prometheus (/graph) nao pinta o canvas no Chrome headless, entao a
# consulta PromQL e mostrada pelo Explore do Grafana usando o datasource Prometheus.
# ponytail: URL do Explore codificada a mao; se a query mudar, regenere o JSON com
#   python3 -c 'import json,urllib.parse as u; ...' (ver README, secao "Prints automaticos").
PANES='%7B%22a%22%3A%20%7B%22datasource%22%3A%20%22prometheus%22%2C%20%22queries%22%3A%20%5B%7B%22refId%22%3A%20%22A%22%2C%20%22datasource%22%3A%20%7B%22type%22%3A%20%22prometheus%22%2C%20%22uid%22%3A%20%22prometheus%22%7D%2C%20%22expr%22%3A%20%22sum%28rate%28http_server_duration_milliseconds_count%7Bservice_name%3D%5C%22shopflow-api%5C%22%7D%5B1m%5D%29%29%22%2C%20%22instant%22%3A%20false%2C%20%22range%22%3A%20true%7D%5D%2C%20%22range%22%3A%20%7B%22from%22%3A%20%22now-15m%22%2C%20%22to%22%3A%20%22now%22%7D%7D%7D'
print_de 16-prometheus-consulta.png 1000 "$GRAFANA_URL/explore?schemaVersion=1&panes=$PANES&orgId=1"

echo "-- evidencia de indisponibilidade (injecao de falha)"
"$BASE/scripts/fault-injection.sh" down >/dev/null 2>&1
echo "   aguardando 60s para os paineis refletirem a falha..."
sleep 60
print_de 17-falha-disponibilidade.png 700 "$(printf "$PAINEL" 2)"
print_de 18-falha-taxa-de-erro.png 700 "$(printf "$PAINEL" 4)"
print_de 19-falha-logs-de-erro.png 800 "$(printf "$PAINEL" 21)"

echo "-- restabelecendo o servico"
"$BASE/scripts/fault-injection.sh" up >/dev/null 2>&1
echo "   aguardando 45s para a recuperacao..."
sleep 45
print_de 20-recuperacao.png 700 "$(printf "$PAINEL" 2)"

echo
echo "Pronto. Prints em $OUT"
ls -1 "$OUT"
