terraform {
  required_version = ">= 1.5.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "docker" {
  # Vazio = usa a variavel de ambiente DOCKER_HOST (ver Makefile / README).
  host = var.docker_host != "" ? var.docker_host : null
}

locals {
  root = abspath(path.module)

  images = {
    prometheus = "prom/prometheus:${var.version_prometheus}"
    loki       = "grafana/loki:${var.version_loki}"
    tempo      = "grafana/tempo:${var.version_tempo}"
    grafana    = "grafana/grafana:${var.version_grafana}"
    collector  = "otel/opentelemetry-collector-contrib:${var.version_otel_collector}"
    api        = "python:${var.version_python}"
    curl       = "curlimages/curl:${var.version_curl}"
  }
}

resource "docker_image" "image" {
  for_each = local.images

  name         = each.value
  keep_locally = true
}

resource "docker_network" "shopflow" {
  name = var.network_name
}

resource "docker_volume" "prometheus" { name = "${var.project_name}-prometheus-data" }
resource "docker_volume" "loki" { name = "${var.project_name}-loki-data" }
resource "docker_volume" "tempo" { name = "${var.project_name}-tempo-data" }
resource "docker_volume" "grafana" { name = "${var.project_name}-grafana-data" }
resource "docker_volume" "api_venv" { name = "${var.project_name}-api-venv" }

# ---------------------------------------------------------------------------
# OpenTelemetry Collector - ponto central de ingestao de metricas, logs e traces
# ---------------------------------------------------------------------------
resource "docker_container" "collector" {
  name          = "otel-collector"
  image         = docker_image.image["collector"].image_id
  restart       = "unless-stopped"
  command       = ["--config=/etc/otel/collector-config.yaml"]
  security_opts = ["label=disable"]

  networks_advanced {
    name = docker_network.shopflow.name
  }

  ports {
    internal = 4317
    external = var.collector_otlp_grpc_port
  }

  ports {
    internal = 4318
    external = var.collector_otlp_http_port
  }

  ports {
    internal = 8888
    external = var.collector_metrics_port
  }

  mounts {
    source    = abspath("${local.root}/configs/otel/collector-config.yaml")
    target    = "/etc/otel/collector-config.yaml"
    type      = "bind"
    read_only = true
  }

  # Leitura do host (somente leitura) para o receiver hostmetrics: CPU, memoria e disco.
  mounts {
    source    = "/"
    target    = "/hostfs"
    type      = "bind"
    read_only = true
  }
}

# ---------------------------------------------------------------------------
# Prometheus - series temporais (recebe remote write do Collector)
# ---------------------------------------------------------------------------
resource "docker_container" "prometheus" {
  name          = "prometheus"
  image         = docker_image.image["prometheus"].image_id
  restart       = "unless-stopped"
  user          = "0"
  security_opts = ["label=disable"]

  command = [
    "--config.file=/etc/prometheus/prometheus.yml",
    "--storage.tsdb.path=/prometheus",
    "--storage.tsdb.retention.time=24h",
    "--web.enable-remote-write-receiver",
    "--web.enable-lifecycle",
  ]

  networks_advanced {
    name = docker_network.shopflow.name
  }

  ports {
    internal = 9090
    external = var.prometheus_port
  }

  mounts {
    source    = abspath("${local.root}/configs/prometheus/prometheus.yml")
    target    = "/etc/prometheus/prometheus.yml"
    type      = "bind"
    read_only = true
  }

  volumes {
    volume_name    = docker_volume.prometheus.name
    container_path = "/prometheus"
  }

  depends_on = [docker_container.collector]
}

# ---------------------------------------------------------------------------
# Loki - agregacao de logs
# ---------------------------------------------------------------------------
resource "docker_container" "loki" {
  name          = "loki"
  image         = docker_image.image["loki"].image_id
  restart       = "unless-stopped"
  user          = "0"
  security_opts = ["label=disable"]
  command       = ["-config.file=/etc/loki/loki-config.yaml"]

  networks_advanced {
    name = docker_network.shopflow.name
  }

  ports {
    internal = 3100
    external = var.loki_port
  }

  mounts {
    source    = abspath("${local.root}/configs/loki/loki-config.yaml")
    target    = "/etc/loki/loki-config.yaml"
    type      = "bind"
    read_only = true
  }

  volumes {
    volume_name    = docker_volume.loki.name
    container_path = "/loki"
  }
}

# ---------------------------------------------------------------------------
# Tempo - rastreamento distribuido + metricas derivadas (service graph)
# ---------------------------------------------------------------------------
resource "docker_container" "tempo" {
  name          = "tempo"
  image         = docker_image.image["tempo"].image_id
  restart       = "unless-stopped"
  user          = "0"
  security_opts = ["label=disable"]
  command       = ["-config.file=/etc/tempo/tempo.yaml"]

  networks_advanced {
    name = docker_network.shopflow.name
  }

  ports {
    internal = 3200
    external = var.tempo_port
  }

  mounts {
    source    = abspath("${local.root}/configs/tempo/tempo.yaml")
    target    = "/etc/tempo/tempo.yaml"
    type      = "bind"
    read_only = true
  }

  volumes {
    volume_name    = docker_volume.tempo.name
    container_path = "/var/tempo"
  }
}

# ---------------------------------------------------------------------------
# Grafana - visualizacao (datasources e dashboard provisionados)
# ---------------------------------------------------------------------------
resource "docker_container" "grafana" {
  name          = "grafana"
  image         = docker_image.image["grafana"].image_id
  restart       = "unless-stopped"
  user          = "0"
  security_opts = ["label=disable"]

  env = [
    "GF_SECURITY_ADMIN_USER=${var.grafana_admin_user}",
    "GF_SECURITY_ADMIN_PASSWORD=${var.grafana_admin_password}",
    "GF_AUTH_ANONYMOUS_ENABLED=true",
    "GF_AUTH_ANONYMOUS_ORG_ROLE=Admin",
    "GF_USERS_ALLOW_SIGN_UP=false",
    "GF_ANALYTICS_REPORTING_ENABLED=false",
    "GF_NEWS_NEWS_FEED_ENABLED=false",
    "GF_DASHBOARDS_MIN_REFRESH_INTERVAL=2s",
    "GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/shopflow.json",
  ]

  networks_advanced {
    name = docker_network.shopflow.name
  }

  ports {
    internal = 3000
    external = var.grafana_port
  }

  mounts {
    source    = abspath("${local.root}/configs/grafana/provisioning")
    target    = "/etc/grafana/provisioning"
    type      = "bind"
    read_only = true
  }

  mounts {
    source    = abspath("${local.root}/configs/grafana/dashboards")
    target    = "/var/lib/grafana/dashboards"
    type      = "bind"
    read_only = true
  }

  volumes {
    volume_name    = docker_volume.grafana.name
    container_path = "/var/lib/grafana"
  }

  depends_on = [docker_container.prometheus, docker_container.loki, docker_container.tempo]
}

# ---------------------------------------------------------------------------
# ShopFlow API - aplicacao monitorada
# ---------------------------------------------------------------------------
resource "docker_container" "api" {
  name          = "shopflow-api"
  image         = docker_image.image["api"].image_id
  restart       = "unless-stopped"
  working_dir   = "/app"
  security_opts = ["label=disable"]

  command = [
    "/bin/sh",
    "-c",
    "if [ ! -x /venv/bin/uvicorn ]; then python -m venv /venv && /venv/bin/pip install --quiet --no-cache-dir -r /app/requirements.txt; fi; exec /venv/bin/uvicorn main:app --app-dir /app --host 0.0.0.0 --port 8000 --log-level warning",
  ]

  env = [
    "OTEL_SERVICE_NAME=shopflow-api",
    "OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317",
    "OTEL_EXPORTER_OTLP_PROTOCOL=grpc",
    "OTEL_EXPORTER_OTLP_INSECURE=true",
    "OTEL_METRIC_EXPORT_INTERVAL=5000",
    "SERVICE_VERSION=1.4.0",
    "DEPLOYMENT_ENV=lab",
    "PYTHONUNBUFFERED=1",
    "PYTHONDONTWRITEBYTECODE=1",
  ]

  networks_advanced {
    name = docker_network.shopflow.name
  }

  ports {
    internal = 8000
    external = var.api_port
  }

  mounts {
    source    = abspath("${local.root}/app")
    target    = "/app"
    type      = "bind"
    read_only = true
  }

  volumes {
    volume_name    = docker_volume.api_venv.name
    container_path = "/venv"
  }

  depends_on = [docker_container.collector]
}

# ---------------------------------------------------------------------------
# Gerador de carga - simula usuarios navegando na loja
# ---------------------------------------------------------------------------
resource "docker_container" "loadgen" {
  name          = "loadgen"
  image         = docker_image.image["curl"].image_id
  restart       = "unless-stopped"
  security_opts = ["label=disable"]
  command       = ["/bin/sh", "/scripts/load-test.sh"]

  env = [
    "API_URL=http://shopflow-api:8000",
    "CYCLE_SLEEP=${var.loadgen_cycle_sleep}",
    "CUSTOMERS=${var.loadgen_customers}",
  ]

  networks_advanced {
    name = docker_network.shopflow.name
  }

  mounts {
    source    = abspath("${local.root}/scripts")
    target    = "/scripts"
    type      = "bind"
    read_only = true
  }

  depends_on = [docker_container.api]
}
