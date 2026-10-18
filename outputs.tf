output "urls" {
  description = "Endpoints expostos no host."
  value = {
    grafana      = "http://localhost:${var.grafana_port}"
    prometheus   = "http://localhost:${var.prometheus_port}"
    loki          = "http://localhost:${var.loki_port}/loki/api/v1/labels"
    tempo        = "http://localhost:${var.tempo_port}/ready"
    shopflow_api = "http://localhost:${var.api_port}/catalog"
    otel_metrics = "http://localhost:${var.collector_metrics_port}/metrics"
    otlp_grpc    = "localhost:${var.collector_otlp_grpc_port}"
  }
}

output "credenciais_grafana" {
  value     = "usuario=${var.grafana_admin_user} senha=${var.grafana_admin_password} (ou acesso anonimo como Admin)"
  sensitive = true
}

output "containers" {
  description = "Containers gerenciados por este state."
  value = [
    docker_container.collector.name,
    docker_container.prometheus.name,
    docker_container.loki.name,
    docker_container.tempo.name,
    docker_container.grafana.name,
    docker_container.api.name,
    docker_container.loadgen.name,
  ]
}
