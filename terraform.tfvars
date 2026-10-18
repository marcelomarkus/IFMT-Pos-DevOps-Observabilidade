# Ajustes locais. Copie de terraform.tfvars.example e adapte se necessario.

# Caminho do socket do Podman (rootless). Deixe vazio para usar DOCKER_HOST.
docker_host = "unix:///run/user/1000/podman/podman.sock"

grafana_admin_password = "shopflow"

# Intensidade do gerador de carga (scripts/load-test.sh)
loadgen_cycle_sleep = 2
loadgen_customers   = 3
