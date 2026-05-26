#!/usr/bin/env bash
# ==============================================================================
# port-forward-all.sh — Expose platform services to your local machine
# ==============================================================================
# This script launches background kubectl port-forwards to expose:
#   - ArgoCD Console:  https://localhost:8080
#   - Grafana UI:      http://localhost:3000
#   - Prometheus API:  http://localhost:9090
# ==============================================================================

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# Ensure we're in the right context
info "Verifying cluster context..."
ctx=$(kubectl config current-context 2>/dev/null || true)
if [[ "$ctx" != "kind-gitops-platform" ]]; then
    fail "Wrong context: '${ctx}'. Expected 'kind-gitops-platform'."
fi

# Function to safely start a port-forward
start_forward() {
    local svc=$1
    local namespace=$2
    local port=$3
    local local_port=$4
    local name=$5

    # Check if already listening on the local port
    if ss -tulpn 2>/dev/null | grep -q ":${local_port} "; then
        warn "${name} port-forward is already active or port ${local_port} is in use."
        return
    fi

    info "Starting port-forward for ${name} to http://localhost:${local_port}..."
    kubectl port-forward "svc/${svc}" -n "${namespace}" "${local_port}:${port}" &>/dev/null &
    
    # Wait to verify it started successfully
    sleep 2
    if ss -tulpn 2>/dev/null | grep -q ":${local_port} "; then
        ok "${name} is accessible at http://localhost:${local_port} (via svc/${svc})"
    else
        fail "Failed to establish port-forward for ${name}."
    fi
}

echo "=================================================="
echo "  GitOps Observability Platform — Port Forwarder"
echo "=================================================="
echo ""

# 1. ArgoCD
start_forward "argocd-server" "argocd" "443" "8080" "ArgoCD Web UI"
echo -e "   -> Username: ${GREEN}admin${NC}"
echo -e "   -> Password: ${GREEN}7o28ksEDomjvLj0a${NC}"
echo ""

# 2. Grafana
start_forward "prometheus-stack-grafana" "monitoring" "80" "3000" "Grafana Dashboards"
echo -e "   -> Username: ${GREEN}admin${NC}"
echo -e "   -> Password: ${GREEN}admin${NC}"
echo ""

# 3. Prometheus
start_forward "prometheus-stack-kube-prom-prometheus" "monitoring" "9090" "9090" "Prometheus Server"
echo ""

echo "=================================================="
ok "All port-forwards initialized in the background."
echo "To terminate them all, run: pkill -f 'port-forward'"
echo "=================================================="
echo ""
