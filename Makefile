# Atalhos para operar a stack ShopFlow com Terraform + Podman.
# O socket do Podman rootless e detectado automaticamente pelo UID do usuario.

SHELL := /bin/bash
export DOCKER_HOST ?= unix:///run/user/$(shell id -u)/podman/podman.sock
export API_URL ?= http://localhost:8000

.DEFAULT_GOAL := help

help: ## Lista os comandos disponiveis
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

init: ## Baixa o provider do Terraform
	terraform init

fmt: ## Formata os arquivos .tf
	terraform fmt -recursive

validate: ## Valida a sintaxe do Terraform
	terraform validate

plan: ## Mostra o que sera criado
	terraform plan

up: ## Sobe toda a stack
	terraform apply -auto-approve
	@echo
	@echo "Aguardando Grafana... (dashboard: http://localhost:3000/d/shopflow-observability)"
	@for i in $$(seq 1 30); do curl -sf http://localhost:3000/api/health >/dev/null && break || sleep 2; done

down: ## Destroi a stack (mantem as imagens)
	terraform destroy -auto-approve

status: ## Lista os containers da stack
	podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

health: ## Verifica a saude dos servicos e o volume de telemetria
	./scripts/check-stack.sh

load: ## Executa um ciclo do gerador de carga no host
	ONCE=1 ./scripts/load-test.sh

fault: ## Simula indisponibilidade da API
	./scripts/fault-injection.sh down

recover: ## Restabelece a API
	./scripts/fault-injection.sh up

logs-collector: ## Logs do OpenTelemetry Collector
	podman logs --tail 40 -f otel-collector

logs-api: ## Logs JSON da aplicacao
	podman logs --tail 40 -f shopflow-api

logs-loadgen: ## Logs do gerador de carga
	podman logs --tail 40 -f loadgen

open: ## Abre o dashboard no navegador
	xdg-open http://localhost:3000/d/shopflow-observability >/dev/null 2>&1 &

taillogs: ## Acompanha os logs de todos os containers
	podman logs -f --tail 10 otel-collector prometheus loki tempo grafana shopflow-api loadgen

cleanup: ## Limpeza de emergencia via Podman
	./scripts/cleanup.sh

.PHONY: help init fmt validate plan up down status health load fault recover logs-collector logs-api logs-loadgen open taillogs cleanup
