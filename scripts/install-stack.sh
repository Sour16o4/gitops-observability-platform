#!/usr/bin/env bash
# ==============================================================================
# install-stack.sh — Install platform components into the KIND cluster
# ==============================================================================
# Phase 1: NGINX Ingress Controller only
# Future phases add: ArgoCD, Prometheus, Grafana, Loki
#
# Usage: bash scripts/install-stack.sh
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

CLUSTER_NAME="gitops-platform"

# Verify we're connected to the right cluster
verify_cluster() {
    info "Verifying cluster context..."
    local ctx
    ctx=$(kubectl config current-context 2>/dev/null || true)
    if [[ "$ctx" != "kind-${CLUSTER_NAME}" ]]; then
        fail "Wrong context: '${ctx}'. Expected 'kind-${CLUSTER_NAME}'. Run: kubectl config use-context kind-${CLUSTER_NAME}"
    fi
    ok "Connected to kind-${CLUSTER_NAME}"
}

# ==============================================================================
# NGINX Ingress Controller
# ==============================================================================
# WHAT IS AN INGRESS CONTROLLER?
# Kubernetes Ingress resources are just declarations: "route /api to service X".
# But an Ingress resource alone does NOTHING. You need a controller — a running
# pod that watches Ingress resources and configures a reverse proxy accordingly.
#
# NGINX Ingress Controller:
# - Runs NGINX inside the cluster as a pod
# - Watches the K8s API for Ingress resources
# - Dynamically generates nginx.conf from Ingress rules
# - Acts as the cluster's "edge router" — all external traffic enters through it
#
# WHY NGINX AND NOT A CLOUD LOADBALANCER?
# - Cloud LBs (ALB, NLB) require a cloud provider. KIND has no cloud.
# - NGINX Ingress is the most widely deployed ingress controller (~40% market share)
# - It works identically in local dev and production (with a real LB in front in prod)
# - You learn the actual routing layer, not a cloud abstraction
# - Interview relevance: "We use NGINX Ingress with host-based routing and
#   path-based routing, fronted by an NLB in production"
#
# TRAFFIC FLOW:
# localhost:80 → Docker port mapping → KIND control-plane:80
#   → NGINX Ingress pod (hostPort) → reads Ingress rules
#   → routes to ClusterIP Service → kube-proxy → Pod
#
# ALTERNATIVE CONTROLLERS:
# - Traefik: auto-TLS, simpler config, but less production adoption
# - HAProxy: high performance, less K8s-native tooling
# - Envoy/Contour: better for gRPC, more complex
# ==============================================================================
install_nginx_ingress() {
    info "Installing NGINX Ingress Controller..."

    # Add the ingress-nginx Helm repository
    # Helm repos are like apt/pacman repositories — they host chart packages.
    # ingress-nginx is maintained by the Kubernetes project itself.
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update

    # Install the chart into namespace ingress-nginx
    # Flags explained:
    #   --create-namespace        → Create the namespace if it doesn't exist
    #   --namespace ingress-nginx → Isolate ingress components from app workloads
    #   --set controller.hostPort.enabled=true
    #       → Makes NGINX listen on the node's actual network ports (80, 443)
    #       → Combined with extraPortMappings, this completes the traffic path:
    #         host:80 → container:80 → NGINX pod listening on hostPort 80
    #   --set controller.service.type=NodePort
    #       → In KIND, we can't use LoadBalancer (no cloud provider to assign IP)
    #       → NodePort exposes the service on each node's IP at a static port
    #       → Combined with hostPort, traffic reaches NGINX directly
    #   --set controller.nodeSelector."ingress-ready"=true
    #       → Schedule NGINX only on nodes labeled ingress-ready=true
    #       → We labeled only the control-plane node (in kind-config.yaml)
    #       → This ensures NGINX runs where extraPortMappings exist
    #   --set controller.tolerations[0].operator=Exists
    #       → Control-plane nodes have a "taint" that repels regular pods
    #       → This toleration says "I'm allowed to run on tainted nodes"
    #       → Without it, NGINX can't schedule on the control-plane
    #   --set controller.watchIngressWithoutClass=true
    #       → Accept Ingress resources even if they don't specify ingressClassName
    #       → Convenience for development; in prod you'd be explicit

    if helm list -n ingress-nginx 2>/dev/null | grep -q ingress-nginx; then
        warn "NGINX Ingress already installed. Upgrading..."
        local CMD="upgrade"
    else
        local CMD="install"
    fi

    helm ${CMD} ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --set controller.hostPort.enabled=true \
        --set controller.service.type=NodePort \
        --set-string controller.nodeSelector."ingress-ready"=true \
        --set controller.tolerations[0].key="" \
        --set controller.tolerations[0].operator=Exists \
        --set controller.watchIngressWithoutClass=true \
        --set controller.metrics.enabled=true \
        --set controller.metrics.serviceMonitor.enabled=false \
        --wait \
        --timeout 120s

    ok "NGINX Ingress Controller installed"

    # Wait for the controller pod to be ready
    info "Waiting for NGINX Ingress controller pod..."
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=120s

    ok "NGINX Ingress controller is ready"
}

# ==============================================================================
# Verify traffic flow: localhost → NGINX → echo service → Pod
# ==============================================================================
# We deploy a temporary echo server to prove the full traffic path works.
# This is your "smoke test" before building the real application.
# ==============================================================================
verify_traffic() {
    info "Deploying test echo server to verify traffic flow..."

    # Create a simple test deployment + service + ingress
    kubectl apply -f - <<'EOF'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-test
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo-test
  template:
    metadata:
      labels:
        app: echo-test
    spec:
      containers:
        - name: echo
          # hashicorp/http-echo: a tiny HTTP server that returns a fixed string.
          # Perfect for testing ingress routing without building anything.
          image: hashicorp/http-echo:latest
          args: ["-text=Traffic flow verified! localhost → Ingress → Service → Pod"]
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: echo-test
  namespace: default
spec:
  # ClusterIP: internal-only IP. Only reachable from inside the cluster.
  # The Ingress controller (which IS inside the cluster) routes to this.
  type: ClusterIP
  selector:
    app: echo-test
  ports:
    - port: 80
      targetPort: 5678  # Maps Service port 80 → container port 5678
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo-test
  namespace: default
spec:
  # ingressClassName: tells K8s which Ingress controller handles this resource.
  # "nginx" matches the class installed by the ingress-nginx Helm chart.
  # Without this, the Ingress might be ignored if watchIngressWithoutClass=false.
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /echo
            # Prefix: matches /echo, /echo/, /echo/anything
            pathType: Prefix
            backend:
              service:
                name: echo-test
                port:
                  number: 80
EOF

    # Wait for the echo pod to be ready
    info "Waiting for echo-test pod..."
    kubectl wait --for=condition=ready pod -l app=echo-test --timeout=60s

    # Give NGINX a moment to pick up the new Ingress rule
    sleep 5

    # Test the full traffic path
    info "Testing: curl localhost/echo"
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/echo 2>/dev/null || echo "000")

    if [[ "$response" == "200" ]]; then
        ok "Traffic flow verified! HTTP 200 from localhost/echo"
        echo ""
        info "Response body:"
        curl -s http://localhost/echo
        echo ""
    else
        warn "Got HTTP ${response}. NGINX may need more time to reload."
        info "Manual test: curl -v http://localhost/echo"
        info "Debug: kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller"
    fi

    # Cleanup test resources
    info "Cleaning up test resources..."
    kubectl delete deployment echo-test --ignore-not-found
    kubectl delete service echo-test --ignore-not-found
    kubectl delete ingress echo-test --ignore-not-found
    ok "Test resources cleaned up"
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    echo ""
    echo "=============================================="
    echo "  GitOps Platform — Stack Installation"
    echo "=============================================="
    echo ""

    verify_cluster
    install_nginx_ingress
    verify_traffic

    echo ""
    echo "=============================================="
    ok "Phase 1 complete: KIND cluster + NGINX Ingress"
    echo "=============================================="
    echo ""
    info "Cluster: kind-${CLUSTER_NAME}"
    info "Ingress: http://localhost (NGINX)"
    info "Next: Build the demo application (Phase 2)"
    echo ""
}

main "$@"
