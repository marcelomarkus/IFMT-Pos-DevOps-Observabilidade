#!/bin/sh
# Gerador de carga da ShopFlow API - simula usuarios navegando na loja.
#
# Uso (host ou container):
#   API_URL=http://localhost:8000 CYCLE_SLEEP=2 CUSTOMERS=3 ./scripts/load-test.sh
#   ONCE=1 ./scripts/load-test.sh        # executa apenas um ciclo (demonstracao rapida)
#
# Variaveis:
#   API_URL       URL base da aplicacao        (padrao: http://localhost:8000)
#   CYCLE_SLEEP   pausa entre ciclos, segundos (padrao: 2)
#   CUSTOMERS     requisicoes simuladas/ciclo  (padrao: 3)
#   ONCE          se definido (1), roda um ciclo e sai

set -u

API_URL="${API_URL:-http://localhost:8000}"
CYCLE_SLEEP="${CYCLE_SLEEP:-2}"
CUSTOMERS="${CUSTOMERS:-3}"
ONCE="${ONCE:-0}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

rand() { # rand MAX -> 1..MAX
  max="$1"
  if [ -n "${RANDOM:-}" ]; then
    echo $((RANDOM % max + 1))
  else
    awk -v m="$max" 'BEGIN{srand();print int(rand()*m)+1}'
  fi
}

request() { # request METODO CAMINHO [JSON]
  method="$1"
  path="$2"
  body="${3:-}"
  if [ -n "$body" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      -X "$method" -H 'Content-Type: application/json' -d "$body" "$API_URL$path")
  else
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X "$method" "$API_URL$path")
  fi
  [ -z "$code" ] && code="000"
  printf '%s' "$code"
}

visit_customer() { # visit_customer N
  n="$1"
  ok=0
  err=0

  code=$(request GET "/catalog")
  log "cliente=$n GET /catalog -> $code"
  [ "$code" = "200" ] && ok=$((ok + 1)) || err=$((err + 1))

  termo=$(printf 'notebook|monitor|fone|teclado|smartphone|cadeira' | tr '|' '\n' | sed -n "$(rand 6)p")
  code=$(request GET "/search?q=$termo")
  log "cliente=$n GET /search?q=$termo -> $code"
  [ "$code" = "200" ] && ok=$((ok + 1)) || err=$((err + 1))

  sku="SKU-100$(rand 6)"
  code=$(request GET "/catalog/$sku")
  log "cliente=$n GET /catalog/$sku -> $code"
  [ "$code" = "200" ] && ok=$((ok + 1)) || err=$((err + 1))

  if [ "$(rand 5)" -eq 1 ]; then
    code=$(request POST "/auth/login")
    log "cliente=$n POST /auth/login -> $code"
    [ "$code" = "200" ] && ok=$((ok + 1)) || err=$((err + 1))
  fi

  if [ "$(rand 4)" -eq 1 ]; then
    items=$(rand 4)
    method=$(printf 'credit_card\npix\nboleto' | sed -n "$(rand 3)p")
    code=$(request POST "/checkout" "{\"items\": $items, \"payment_method\": \"$method\"}")
    log "cliente=$n POST /checkout (itens=$items pagamento=$method) -> $code"
    [ "$code" = "200" ] && ok=$((ok + 1)) || err=$((err + 1))
  fi

  return 0
}

log "gerador de carga iniciado: $API_URL (clientes por ciclo=$CUSTOMERS, intervalo=${CYCLE_SLEEP}s)"

# Aquecimento: aguarda a API responder antes de comecar.
tentativas=0
while [ "$tentativas" -lt 30 ]; do
  code=$(request GET "/healthz")
  [ "$code" = "200" ] || [ "$code" = "503" ] && break
  tentativas=$((tentativas + 1))
  sleep 2
done

cycle=0
while true; do
  cycle=$((cycle + 1))
  log "--- ciclo $cycle ---"
  i=1
  while [ "$i" -le "$CUSTOMERS" ]; do
    visit_customer "$i"
    i=$((i + 1))
  done
  [ "$ONCE" = "1" ] && break
  sleep "$CYCLE_SLEEP"
done

log "gerador de carga finalizado"
