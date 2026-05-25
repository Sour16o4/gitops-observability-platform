#!/usr/bin/env bash
# ==============================================================================
# port-forward-all.sh — Forward all platform services to localhost
# ==============================================================================
# Kubernetes services are internal by default (ClusterIP). Port-forwarding
# creates a tunnel from your host machine into the cluster so you can
# access dashboards and APIs from your browser.
#
# Usage: bash scripts/port-forward-all.sh
# Stop:  Ctrl+C (kills all background port-forwards)
# ==============================================================================

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

# Array to track background PIDs for cleanup
PIDS=()

cleanup() {
    echo ""
    info "Stopping all port-forwards..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    ok "All port-forwards stopped"
}
trap cleanup EXIT INT TERM

# Port-forward helper: starts kubectl port-forward in background
# Arguments: namespace, service-name, local-port, remote-port, description
pf() {
    local ns=$1 svc=$2 local_port=$3 remote_port=$4 desc=$5
    # Check if the service exists before trying to forward
    if kubectl get svc "$svc" -n "$ns" &>/dev/null; then
        kubectl port-forward -n "$ns" "svc/$svc" "${local_port}:${remote_port}" &>/dev/null &
        PIDS+=($!)
        ok "${desc}: http://localhost:${local_port}"
    else
        info "Skipping ${desc} (service ${svc} not found in ${ns})"
    fi
}

echo ""
echo "=============================================="
echo "  Port Forwards — GitOps Platform"
echo "=============================================="
echo ""

# Phase 4: ArgoCD
pf argocd    argocd-server           8080 443  "ArgoCD UI"

# Phase 5: Monitoring
pf monitoring prometheus-kube-prometheus-prometheus 9090 9090 "Prometheus"
pf monitoring prometheus-grafana                    3000 80   "Grafana"

echo ""
info "Press Ctrl+C to stop all port-forwards"
echo ""

# Wait forever (until Ctrl+C)
wait
