#!/usr/bin/env bash
# ==============================================================================
# bootstrap-cluster.sh — Install prerequisites and create the KIND cluster
# ==============================================================================
# Run this ONCE to go from a fresh Arch Linux install to a working K8s cluster.
# Idempotent: safe to re-run (checks for existing installs).
#
# Usage: bash scripts/bootstrap-cluster.sh
# ==============================================================================

set -euo pipefail  # -e: exit on error, -u: error on undefined vars, -o pipefail: catch pipe failures

# Colors for output readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

CLUSTER_NAME="gitops-platform"
KIND_CONFIG="$(dirname "$0")/../kind-config.yaml"

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# ==============================================================================
# STEP 0: Verify Arch Linux and cgroup v2
# ==============================================================================
# WHY: KIND with Docker requires cgroup v2 on modern kernels.
# Arch Linux defaults to cgroup v2 (unified hierarchy) since ~2021.
# If your system still has cgroup v1, Docker containers can't manage
# resource limits properly, and kubelet may refuse to start.
#
# HOW TO CHECK: If /sys/fs/cgroup/cgroup.controllers exists, you're on v2.
# ==============================================================================
check_cgroup() {
    info "Checking cgroup version..."
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        ok "cgroup v2 (unified) detected"
    else
        warn "cgroup v2 not detected. Checking /proc/cgroups..."
        # Fallback: check if hierarchy column shows 0 (unified = cgroup v2)
        if grep -q "^cpu[[:space:]]0" /proc/cgroups 2>/dev/null; then
            ok "cgroup v2 detected via /proc/cgroups"
        else
            fail "cgroup v1 detected. See docs/architecture.md for migration steps."
        fi
    fi
}

# ==============================================================================
# STEP 1: Install Docker
# ==============================================================================
# WHY DOCKER (not Podman):
# - KIND officially supports Docker. Podman support is experimental.
# - Docker uses containerd under the hood, same as production K8s.
# - Fewer edge cases on Arch with Docker than rootless Podman + KIND.
#
# ARCH LINUX GOTCHA:
# - The `docker` package in Arch includes Docker Engine + CLI + containerd.
# - You MUST enable and start the docker.service systemd unit.
# - You MUST add your user to the `docker` group to avoid needing sudo.
#   (The docker socket /var/run/docker.sock is owned by root:docker)
# ==============================================================================
install_docker() {
    if command -v docker &>/dev/null; then
        ok "Docker already installed: $(docker --version)"
    else
        info "Installing Docker..."
        sudo pacman -S --needed --noconfirm docker
        ok "Docker installed"
    fi

    # Enable and start Docker daemon via systemd
    # --now = enable (auto-start on boot) + start (start right now)
    if ! systemctl is-active --quiet docker; then
        info "Starting Docker service..."
        sudo systemctl enable --now docker
        ok "Docker service started"
    else
        ok "Docker service already running"
    fi

    # Add current user to docker group (avoids sudo for every docker command)
    # NOTE: You MUST log out and back in (or run `newgrp docker`) for this
    # to take effect. This is a classic Arch gotcha.
    if ! groups | grep -q docker; then
        info "Adding $USER to docker group..."
        sudo usermod -aG docker "$USER"
        warn "You MUST run 'newgrp docker' or log out/in for group change to apply"
    else
        ok "User $USER already in docker group"
    fi

    # Verify Docker works
    if docker info &>/dev/null; then
        ok "Docker is functional"
    else
        warn "Docker installed but 'docker info' failed. Try: newgrp docker"
    fi
}

# ==============================================================================
# STEP 2: Install kubectl
# ==============================================================================
# kubectl is the CLI for talking to the Kubernetes API server.
# Every command you run (get pods, apply manifests, etc.) goes through
# the API server via your kubeconfig credentials.
#
# WHY NOT install via pacman:
# - pacman's kubectl version may lag behind. We want to be careful to
#   ensure version compatibility with KIND's Kubernetes version.
# ==============================================================================
# pacman's kubectl version may lag behind. We use the official binary
# to ensure version compatibility with KIND's Kubernetes version.
# ==============================================================================
install_kubectl() {
    if command -v kubectl &>/dev/null; then
        ok "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    else
        info "Installing kubectl..."
        sudo pacman -S --needed --noconfirm kubectl
        ok "kubectl installed"
    fi
}

# ==============================================================================
# STEP 3: Install KIND
# ==============================================================================
# KIND = Kubernetes IN Docker. It creates K8s clusters using Docker containers
# as nodes. The `kind` binary is a single Go binary — no dependencies beyond Docker.
#
# WHAT HAPPENS WHEN YOU RUN `kind create cluster`:
# 1. Pulls the kindest/node Docker image (contains kubelet, kubeadm, etc.)
# 2. Starts N Docker containers (1 per node in your config)
# 3. Runs kubeadm init on the control-plane container
# 4. Joins worker containers to the cluster via kubeadm join
# 5. Writes a kubeconfig entry to ~/.kube/config
# ==============================================================================
install_kind() {
    if command -v kind &>/dev/null; then
        ok "KIND already installed: $(kind version)"
    else
        info "Installing KIND..."
        # Install from Arch community repo or via Go install
        if pacman -Qi kind &>/dev/null 2>&1; then
            ok "KIND available via pacman"
        else
            # Download official binary
            local KIND_VERSION
            KIND_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
            info "Downloading KIND ${KIND_VERSION}..."
            curl -Lo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
            chmod +x /tmp/kind
            sudo mv /tmp/kind /usr/local/bin/kind
        fi
        ok "KIND installed: $(kind version)"
    fi
}

# ==============================================================================
# STEP 4: Install Helm
# ==============================================================================
# Helm is the package manager for Kubernetes. A "Helm chart" is a templated
# bundle of K8s manifests with configurable values.
#
# WHY HELM (not raw manifests):
# - Parameterized deployments (same chart, different values per environment)
# - Dependency management (chart depends on another chart)
# - Rollback support (helm rollback <release> <revision>)
# - Community charts (prometheus, grafana, ingress-nginx) save weeks of work
# - Interview relevance: every production K8s team uses Helm or Kustomize
# ==============================================================================
install_helm() {
    if command -v helm &>/dev/null; then
        ok "Helm already installed: $(helm version --short)"
    else
        info "Installing Helm..."
        sudo pacman -S --needed --noconfirm helm
        ok "Helm installed"
    fi
}

# ==============================================================================
# STEP 5: Create the KIND cluster
# ==============================================================================
# This is where everything comes together.
#
# `kind create cluster` flags explained:
#   --name gitops-platform    → Names the cluster. Shows in `kind get clusters`.
#                                Also sets kubeconfig context to `kind-gitops-platform`.
#   --config kind-config.yaml → Uses our multi-node config with port mappings.
#   --wait 120s               → Waits up to 120s for the control plane to be ready.
#                                Without this, the command returns immediately and
#                                kubectl commands may fail because apiserver isn't up.
#
# WHAT IS A KUBECONFIG CONTEXT?
# ~/.kube/config can contain credentials for MULTIPLE clusters.
# A "context" = cluster + user + namespace binding.
# `kubectl config use-context kind-gitops-platform` switches which cluster
# your kubectl commands target. This is how you'd switch between
# dev/staging/prod clusters in a real job.
#
# COMMON GOTCHA:
# If ports 80 or 443 are already in use (another web server, previous KIND cluster),
# cluster creation will fail with "port already allocated". Check with:
#   sudo lsof -i :80
#   sudo lsof -i :443
# ==============================================================================
create_cluster() {
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        warn "Cluster '${CLUSTER_NAME}' already exists. Delete with: kind delete cluster --name ${CLUSTER_NAME}"
        ok "Using existing cluster"
    else
        info "Creating KIND cluster '${CLUSTER_NAME}'..."
        info "This pulls the kindest/node image and bootstraps K8s. Takes 2-4 minutes."

        # Check if ports are available
        for port in 80 443; do
            if sudo lsof -i ":${port}" &>/dev/null 2>&1; then
                fail "Port ${port} is already in use. Free it before creating the cluster."
            fi
        done

        kind create cluster \
            --name "${CLUSTER_NAME}" \
            --config "${KIND_CONFIG}" \
            --wait 120s

        ok "Cluster '${CLUSTER_NAME}' created successfully"
    fi

    # Verify kubectl can reach the cluster
    info "Verifying cluster connectivity..."
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"
    ok "kubectl connected to cluster"

    # Show nodes — you should see 1 control-plane + 2 workers
    info "Cluster nodes:"
    kubectl get nodes -o wide
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    echo ""
    echo "=============================================="
    echo "  GitOps Observability Platform — Bootstrap"
    echo "=============================================="
    echo ""

    check_cgroup
    install_docker
    install_kubectl
    install_kind
    install_helm
    create_cluster

    echo ""
    echo "=============================================="
    ok "Phase 1A complete: Cluster is running"
    echo "=============================================="
    echo ""
    info "Next step: Run 'bash scripts/install-stack.sh' to install NGINX Ingress"
    info "Kubeconfig context: kind-${CLUSTER_NAME}"
    info "Switch context: kubectl config use-context kind-${CLUSTER_NAME}"
    echo ""
}

main "$@"
