#!/bin/sh
# Limpeza de emergencia: remove containers, rede e volumes da stack ShopFlow
# diretamente pelo Podman (util quando o state do Terraform ficou inconsistente).
#
# Uso: ./scripts/cleanup.sh
# Preferencia: 'terraform destroy' (remove apenas o que foi criado pelo Terraform).

set -u

containers="otel-collector prometheus loki tempo grafana shopflow-api loadgen"
volumes="shopflow-prometheus-data shopflow-loki-data shopflow-tempo-data shopflow-grafana-data shopflow-api-venv"
network="shopflow-net"

echo "Removendo containers..."
for c in $containers; do
  podman rm -f "$c" >/dev/null 2>&1 && echo "  removido: $c" || true
done

echo "Removendo rede..."
podman network rm "$network" >/dev/null 2>&1 && echo "  removida: $network" || true

echo "Removendo volumes..."
for v in $volumes; do
  podman volume rm "$v" >/dev/null 2>&1 && echo "  removido: $v" || true
done

echo "Concluido. Para recriar tudo: terraform apply -auto-approve"
