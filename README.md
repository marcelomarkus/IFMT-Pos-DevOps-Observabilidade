# ShopFlow - Laboratório de Observabilidade (Terraform + Podman)

<p align="center">
  <img src="./ifmt.png" alt="IFMT" width="270" />
</p>


Implementação prática do projeto basico de observabilidade da plataforma **ShopFlow**.
Toda a infraestrutura e criada como código com **Terraform** e executada em containers
**Podman** (rootless, sem Docker), cobrindo os três pilares da observabilidade:

| Pilar | Backend | Como chega la |
| --- | --- | --- |
| Metricas | Prometheus | `prometheusremotewrite` do OpenTelemetry Collector |
| Logs | Loki | OTLP nativo (`/otlp/v1/logs`) |
| Rastreamentos | Tempo | OTLP gRPC |

A aplicacao (`shopflow-api`) é um microsserviço **FastAPI** instrumentado com o SDK do
OpenTelemetry: emite métricas de negócio (RED + pedidos), logs em JSON com `trace_id` e
spans (HTTP automático + span de negócio `payment.authorize`). Alem disso o Collector coleta
métricas do host (CPU, memória, disco, rede) com o receiver `hostmetrics`.

## 1. Arquitetura

```
   scripts/load-test.sh  (usuarios simulados)          /hostfs (profile: CPU, RAM, disco)
              |                                                   |
              v                                                   v
     +--------------------+   OTLP/gRPC gRPC   +---------------------------------+
     |  shopflow-api      |------------------>|        otel-collector           |
     |  FastAPI + OTel    |   :4317 / :4318   |  recebe, processa e exporta     |
     |  :8000             |                   +----------------+----------------+
     +--------------------+                                    |
                        +-------------------------------------+-------------------------------+
                        |                                     |                               |
          remote write  |                       OTLP/HTTP     |                 OTLP/gRPC     |
                        v                       (logs)        v                 (traces)      v
                 +-------------+                        +-------------+                 +-------------+
                 | Prometheus  |                        |    Loki     |                 |    Tempo    |
                 |   :9090     |                        |   :3100     |                 |   :3200     |
                 +------+------+                        +------+------+                 +------+------+
                        ^                                      |                               |
                        |                                      |                               |
                        |  métricas derivadas dos spans        |                               |
                        +--------------------------------------+-------------------------------+
                                                                               |
                                                                               v
                                                                      +-----------------+
                                                                      |    Grafana      |
                                                                      |     :3000       |
                                                                      | dashboard unico |
                                                                      +-----------------+
```

## 2. Pre-requisitos

- Podman >= 4 com o socket ativo (rootless):
  ```bash
  systemctl --user enable --now podman.socket
  export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock
  ```
  (o provider do Terraform fala a API compativel com Docker exposta pelo Podman)
- Terraform >= 1.5
- ~2 GB de disco para as imagens e ~1,5 GB de RAM para a stack
- Portas livres no host: **3000** Grafana, **3100** Loki, **3200** Tempo, **4317/4318** e **8888** Collector, **8000** API, **9090** Prometheus
- Acesso a internet apenas na primeira execucao (pull das imagens e instalacao das dependencias Python)

> Fedora/RHEL com SELinux: os containers usam `security_opts = ["label=disable"]` para
> permitir a leitura dos arquivos de configuracao montados a partir deste diretorio.

## 3. Como executar

```bash
# 1. Socket do Podman
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock

# 2. Subir a stack (cria rede, volumes, 7 containers)
terraform init
terraform apply -auto-approve        # equivale a: make up

# 3. Conferir saude e volume de telemetria
./scripts/check-stack.sh             # equivale a: make health
```

Saida esperada do `terraform apply`:

```
Apply complete! Resources: 20 added, 0 changed, 0 destroyed.
```

O primeiro start da API instala as dependencias Python em um volume dedicado
(`shopflow-api-venv`), levando cerca de 1 minuto. Nos start seguintes e instantaneo.

### Acessos

| Servico | URL | Credenciais |
| --- | --- | --- |
| Grafana | http://localhost:3000 | `admin` / `shopflow` (ou anonimo, ja como Admin) |
| Dashboard | http://localhost:3000/d/shopflow-observability | - |
| Prometheus | http://localhost:9090 | - |
| Loki | http://localhost:3100/loki/api/v1/labels | - |
| Tempo | http://localhost:3200/ready | - |
| ShopFlow API | http://localhost:8000/catalog | - |
| Metricas do Collector | http://localhost:8888/metrics | - |

## 4. Scripts de simulacao

Todos ficam em `scripts/` e sao idempotentes. O gerador de carga ja roda automaticamente
como container (`loadgen`); os scripts no host servem para regular a carga e injetar falhas.

| Script | Para que serve | Exemplo |
| --- | --- | --- |
| `load-test.sh` | Simula usuarios navegando (catalogo, busca, login e checkout) | `ONCE=1 ./scripts/load-test.sh` ou `CUSTOMERS=5 CYCLE_SLEEP=1 ./scripts/load-test.sh` |
| `fault-injection.sh` | Injeta indisponibilidade (HTTP 503) e restabelece o servico | `./scripts/fault-injection.sh down` / `up` / `status` |
| `check-stack.sh` | Verifica a saude dos 5 servicos e quanto de telemetria ja foi armazenada | `./scripts/check-stack.sh` |
| `coletar-evidencias.sh` | Salva evidencias textuais de todas as verificacoes em `evidencias/` | `./scripts/coletar-evidencias.sh` |
| `cleanup.sh` | Limpeza de emergencia via Podman (quando o state ficou inconsistente) | `./scripts/cleanup.sh` |

Variaveis aceitas pelo gerador de carga: `API_URL`, `CUSTOMERS` (requisicoes por ciclo),
`CYCLE_SLEEP` (pausa entre ciclos), `ONCE=1` (um unico ciclo).

```bash
# Carga mais intensa por 1 minuto, a partir do host
CUSTOMERS=5 CYCLE_SLEEP=1 ./scripts/load-test.sh

# Demonstrar indisponibilidade e recuperacao (gera erro 5xx + logs de erro)
./scripts/fault-injection.sh down
sleep 60
./scripts/fault-injection.sh up
```

## 5. Instrumentacao: o que esta sendo observado

### Metricas (Prometheus)

| Metrica | Tipo | Significado |
| --- | --- | --- |
| `http_server_duration_milliseconds_*` | histograma | Latencia de todas as rotas HTTP (instrumentacao automatica do FastAPI) |
| `shopflow_orders_completed_total` | contador | Pedidos aprovados no checkout |
| `shopflow_orders_failed_total` | contador | Pedidos rejeitados pelo gateway de pagamento |
| `shopflow_auth_failures_total` | contador | Falhas de autenticacao (401) |
| `shopflow_checkout_duration_milliseconds_*` | histograma | Duracao total do fluxo de checkout |
| `shopflow_payment_duration_milliseconds_*` | histograma | Latencia do gateway de pagamento |
| `shopflow_search_duration_milliseconds_*` | histograma | Latencia da busca de produtos |
| `shopflow_cart_value_BRL_*` | histograma | Valor do carrinho (ticket dos pedidos) |
| `shopflow_availability_ratio` | gauge | Disponibilidade sintetica: `1` disponivel, `0` indisponivel |
| `shopflow_payment_queue_size_ratio` | gauge | Itens na fila de pagamento |
| `system_cpu_time_seconds_total`, `system_memory_usage_bytes`, `system_filesystem_usage_bytes`, `system_network_io_bytes_total` | hostmetrics | CPU, memória, disco e rede do host |
| `traces_spanmetrics_*`, `traces_service_graph_*` | derived (Tempo) | Latencia e chamadas derivadas dos rastreamentos |

### Logs (Loki)

Cada linha e um JSON com: `timestamp`, `level`, `service`, `message`, `trace_id`, `span_id`
e campos de negócio (`order.id`, `payment.method`, `cart.items`, `cart.value`, `auth.reason`).
O `trace_id` aparece como metadado estruturado e como campo derivado no Grafana, o que permite
saltar do log direto para o rastreamento correspondente.

### Rastreamentos (Tempo)

- Span automático do FastAPI para cada requisicao HTTP (rota, metodo e codigo de status).
- Span de negócio `payment.authorize` com `order.id`, `payment.method`, `cart.items`,
  `cart.value` e `payment.gateway.status`; falhas marcam o span com `StatusCode.ERROR`.

## 6. Estrutura de arquivos

```
observabilidade-shopflow/
├── main.tf                  # rede, volumes, imagens e os 7 containers
├── variables.tf             # portas, versoes das imagens e intensidade da carga
├── outputs.tf               # URLs e credenciais apos o apply
├── terraform.tfvars         # valores locais (socket do Podman, senha do Grafana)
├── Makefile                 # atalhos: make up / health / fault / logs-api ...
├── app/
│   ├── main.py              # API FastAPI instrumentada com OpenTelemetry
│   └── requirements.txt     # dependencias fixadas
├── configs/
│   ├── otel/collector-config.yaml        # receivers, processors e exporters
│   ├── prometheus/prometheus.yml         # scrape + remote write receiver
│   ├── loki/loki-config.yaml             # single binary, schema v13, metadados
│   ├── tempo/tempo.yaml                  # traces + span metrics/service graph
│   └── grafana/
│       ├── provisioning/datasources/datasources.yaml
│       ├── provisioning/dashboards/dashboards.yaml
│       └── dashboards/shopflow.json      # dashboard provisionado (21 paineis)
├── scripts/
│   ├── load-test.sh         # envio de carga continua contra a API
│   ├── fault-injection.sh   # injeta/restabelece indisponibilidade (down/up/status)
│   ├── check-stack.sh       # verificacao de saude de todos os servicos
│   ├── coletar-evidencias.sh # salva métricas, traces e logs em evidencias/ (*.txt)
│   ├── capturar-prints.sh   # gera os prints PNG das telas em evidencias/prints/
│   └── cleanup.sh           # limpeza forcada pelo Podman
└── evidencias/              # gerado por coletar-evidencias.sh (txt) e capturar-prints.sh (prints/)
```

Tudo o que aparece no Grafana (datasources e dashboard) e provisionado por arquivo: nao ha
configuracao feita manualmente pela interface.

## 7. Roteiro de prints (evidencias)

Execute `terraform apply` e aguarde ~1 minuto (a API precisa subir e o load generator comecar
a enviar telemetria). Depois siga a ordem abaixo; cada item indica o comando e o que deve
aparecer na imagem.

| # | Print | Como gerar | O que deve aparecer |
| --- | --- | --- | --- |
| 1 | Infraestrutura como código | `terraform apply -auto-approve` | `Apply complete! Resources: 20 added, 0 changed, 0 destroyed.` e a lista de outputs |
| 2 | Containers na stack | `make status` (ou `podman ps`) | 7 containers `Up`: tempo, loki, otel-collector, shopflow-api, loadgen, prometheus, grafana |
| 3 | Dashboard - visao RED | abrir http://localhost:3000/d/shopflow-observability | Disponibilidade **DISPONIVEL** (verde), requisicoes/s, taxa de erro, latencia p95 e os graficos de trafego por rota |
| 4 | Dashboard - métricas de negócio | rolar ate a secao 2 | Pedidos concluidos, falhas, latencia do gateway de pagamento e fila, span metrics |
| 5 | Dashboard - infraestrutura | secao 3 | CPU (%), memória, gauge de disco `/` e rede do host |
| 6 | Rastreamento distribuido | secao 4, clicar em um trace | Arvore de spans com `GET /checkout` + `payment.authorize`, atributos de negócio e duracao |
| 7 | Logs correlacionados | secao 4, expandir um log | JSON com `trace_id`, `order.id`, `payment.method`; ao clicar no `trace_id` o Grafana abre o trace |
| 8 | Indisponibilidade (falha) | `./scripts/fault-injection.sh down` e aguardar ~1 min | Painel de disponibilidade vermelho (**INDISPONIVEL**), taxa de erro subindo, logs de erro |
| 9 | Recuperacao | `./scripts/fault-injection.sh up` e aguardar ~1 min | Disponibilidade volta a verde e a taxa de erro cai |
| 10 | Prometheus | http://localhost:9090/targets | Alvos `UP` (`prometheus`, `otel-collector`) e o grafico de uma metrica (ex.: `sum(shopflow_orders_completed_total)`) |
| 11 | Logs do gerador de carga | `make logs-loadgen` | Requisicoes por ciclo com os codigos `200`, `401` e `502` |
| 12 | Collector processando | `make logs-collector` | Linhas do exporter `debug` com `"spans": N` a cada 5 s |
| 13 | Verificacao consolidada | `./scripts/check-stack.sh` | Todos os servicos `200`, contagem de métricas, logs e traces |
| 14 | Evidencias textuais | `./scripts/coletar-evidencias.sh` | Arquivos `01..14` em `evidencias/` (inclui o valor atual de cada painel) |

Dica para os prints dos dados de negócio: rode `CUSTOMERS=5 CYCLE_SLEEP=1 ./scripts/load-test.sh`
em paralelo para o dashboard ficar mais movimentado.

### Prints automáticos (opcional)

`./scripts/capturar-prints.sh` gera automaticamente 20 imagens PNG em `evidencias/prints/`
(do `01-dashboard-completo.png` ao `20-recuperacao.png`), usando o Chrome em modo headless.
Requer o Google Chrome (ou Chromium) instalado e a stack em execucao. O script cobre: dashboard
completo, cada secao de paineis, os alvos do Prometheus, os traces e logs e, ao final, injeta a
falha e captura a indisponibilidade e a recuperacao.

Observacao: o grafico nativo do Prometheus (`/graph`) nao renderiza no Chrome headless (o canvas
nao e pintado), por isso o print da consulta PromQL (`16-prometheus-consulta.png`) usa o Explore
do Grafana apontando para o datasource Prometheus. No navegador normal o `/graph` do Prometheus
funciona sem problemas.

## 8. Operacao do dia a dia

```bash
make up            # terraform apply + espera o Grafana
make status        # containers
make health        # verificacao de saude e telemetria
make load          # um ciclo de carga no host
make fault         # simula indisponibilidade
make recover       # restabelece
make logs-api      # logs JSON da aplicacao
make taillogs      # logs de todos os containers
make down          # terraform destroy (mantem as imagens em cache)
make cleanup       # limpeza forçada pelo Podman
```

Depois de alterar arquivos em `configs/`:

```bash
podman restart otel-collector        # ou o container afetado
curl -X POST http://localhost:9090/-/reload          # Prometheus recarrega config
podman restart shopflow-api          # aplicacao (o codigo e montado do disco)
```

O Grafana recarrega os dashboards provisionados automaticamente a cada 10 s.

## 9. Solucao de problemas

| Sintoma | Causa / solucao |
| --- | --- |
| `Unable to create container: statfs ...: no such file or directory` | caminho de bind mount relativo; o projeto usa `abspath()` porque o Podman resolve caminhos relativos a partir do diretorio do daemon |
| Container de dados morre com `permission denied` no volume | volumes nomeados pertencem ao root mapeado; por isso Prometheus, Loki, Tempo e Grafana sobem com `user = "0"` |
| `Error: container exited immediately` no `terraform apply` | algum container nao permaneceu em execucao; veja `podman logs <container>` |
| Porta ja utilizada | altere a variavel correspondente (`*_port`) em `terraform.tfvars` e rode `terraform apply` |
| Loki `/ready` retorna `503` | esperado: o compactor aguarda a estabilidade do ring (ate ~10 min). As consultas funcionam; use `/loki/api/v1/labels` para verificar |
| Tempo loga `error calling scheduler ... no jobs found` periodicamente | ruido cosmetico do modo single binary do Tempo 3.0, sem impacto nos traces |
| Como verificar o socket do Podman | `curl --unix-socket $XDG_RUNTIME_DIR/podman/podman.sock http://d/v5.0.0/libpod/_ping` deve responder `OK` |

## 10. Encerramento

```bash
terraform destroy -auto-approve     # remove os 20 recursos; as imagens ficam em cache
./scripts/cleanup.sh                # alternativa forçada, direto pelo Podman
```
