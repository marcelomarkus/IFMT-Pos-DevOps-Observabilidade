variable "docker_host" {
  description = "Socket da API Docker/Podman (ex.: unix:///run/user/1000/podman/podman.sock). Vazio usa DOCKER_HOST."
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Prefixo dos recursos criados."
  type        = string
  default     = "shopflow"
}

variable "network_name" {
  description = "Nome da rede Podman compartilhada pelos containers."
  type        = string
  default     = "shopflow-net"
}

# --- versoes das imagens -----------------------------------------------------
variable "version_prometheus" {
  type    = string
  default = "v3.13.4"
}

variable "version_loki" {
  type    = string
  default = "3.6.18"
}

variable "version_tempo" {
  type    = string
  default = "3.0.4"
}

variable "version_grafana" {
  type    = string
  default = "13.0.11"
}

variable "version_otel_collector" {
  type    = string
  default = "0.163.1"
}

variable "version_python" {
  type    = string
  default = "3.12-slim"
}

variable "version_curl" {
  type    = string
  default = "8.23.0"
}

# --- portas publicadas no host ----------------------------------------------
variable "grafana_port" {
  type    = number
  default = 3000
}

variable "prometheus_port" {
  type    = number
  default = 9090
}

variable "loki_port" {
  type    = number
  default = 3100
}

variable "tempo_port" {
  type    = number
  default = 3200
}

variable "api_port" {
  type    = number
  default = 8000
}

variable "collector_otlp_grpc_port" {
  type    = number
  default = 4317
}

variable "collector_otlp_http_port" {
  type    = number
  default = 4318
}

variable "collector_metrics_port" {
  type    = number
  default = 8888
}

# --- credenciais e carga -----------------------------------------------------
variable "grafana_admin_user" {
  type    = string
  default = "admin"
}

variable "grafana_admin_password" {
  type      = string
  default   = "shopflow"
  sensitive = true
}

variable "loadgen_cycle_sleep" {
  description = "Intervalo (segundos) entre ciclos do gerador de carga."
  type        = number
  default     = 2
}

variable "loadgen_customers" {
  description = "Quantidade de requisicoes simuladas por ciclo."
  type        = number
  default     = 3
}
