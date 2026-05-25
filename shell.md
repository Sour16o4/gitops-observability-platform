# Shell Command Log — Phase 1 Bootstrap

## Current System State (Pre-Reboot)

```
$ uname -r
6.19.10-arch1-1          ← Running kernel (OLD)

$ ls /lib/modules/
7.0.7-arch2-1/           ← Only modules available (NEW)

$ systemctl is-active docker
failed                   ← Docker can't start (kernel/module mismatch)
```

## ❌ BLOCKER: Kernel/Module Mismatch

Arch Linux updated the kernel from `6.19.10` → `7.0.7` via pacman, but a **reboot is required** for the new kernel to load. The old kernel's modules have been deleted from disk, so Docker's iptables/nftables subsystem can't load `nf_tables` — causing the startup failure.

**This cannot be fixed without a reboot.**

---

## ✅ Action Required: Reboot

```bash
sudo reboot
```

---

## After Reboot — Run These Commands In Order

### 1. Verify kernel matches modules

```bash
uname -r
# Expected output: 7.0.7-arch2-1
```

### 2. Verify Docker started automatically

```bash
systemctl status docker | head -5
# Expected: "Active: active (running)"
# If it says "failed" or "inactive", run:
#   sudo systemctl start docker
```

### 3. Add yourself to docker group (if not already done)

```bash
sudo usermod -aG docker $USER
newgrp docker
```

### 4. Verify Docker works without sudo

```bash
docker info | head -5
# Expected: Shows "Server Version: ..." with no permission errors
```

### 5. Install KIND (not in Arch repos)

```bash
curl -Lo /tmp/kind "https://kind.sigs.k8s.io/dl/$(curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')/kind-linux-amd64"
chmod +x /tmp/kind
sudo mv /tmp/kind /usr/local/bin/kind
kind version
# Expected: kind v0.27.x or similar
```

### 6. Create the KIND cluster

```bash
cd ~/enterprise/gitops-observability-platform
kind create cluster --name gitops-platform --config kind-config.yaml --wait 120s
# Takes 2-4 minutes. Creates 3 Docker containers (1 control-plane + 2 workers).
```

### 7. Verify cluster nodes

```bash
kubectl get nodes
# Expected:
# NAME                             STATUS   ROLES           AGE   VERSION
# gitops-platform-control-plane    Ready    control-plane   1m    v1.x.x
# gitops-platform-worker           Ready    <none>          1m    v1.x.x
# gitops-platform-worker2          Ready    <none>          1m    v1.x.x
```

### 8. Install NGINX Ingress + verify traffic

```bash
bash scripts/install-stack.sh
# This installs NGINX Ingress Controller via Helm,
# deploys a test echo server, verifies localhost:80 routes to a pod,
# then cleans up test resources.
```

### 9. Final validation

```bash
kubectl get pods -A
# All pods should be Running or Completed

docker port gitops-platform-control-plane
# Expected:
# 80/tcp -> 127.0.0.1:80
# 443/tcp -> 127.0.0.1:443

kubectl get ingressclass
# Expected: "nginx" listed
```

---

## After All 9 Steps Pass

Reply: **"Phase 1 complete, proceed to Phase 2"**

Phase 2 builds the Go demo app, multi-stage Dockerfile, and fully annotated Helm chart.
