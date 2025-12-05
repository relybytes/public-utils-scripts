#!/usr/bin/env bash
set -euo pipefail

# Minimal k3s installer with optional ingress (Traefik or ingress-nginx) and optional MetalLB for LoadBalancer support.

# Determine the target user to run interactive prompts and hints for
INVOKED_USER="$(whoami)"
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  USER_NAME="${SUDO_USER}"
else
  USER_NAME="${INVOKED_USER}"
fi

# Sudo wrapper if not root
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

read -r -p "Install k3s on this host? [Y/n] " install_ans
install_ans="${install_ans:-y}"
if [[ ! "${install_ans,,}" =~ ^(y|yes)$ ]]; then
  echo "Aborting k3s installation."
  exit 0
fi

read -r -p "Do you want an ingress controller that manages automatic exposure? [y/N] " want_ingress
want_ingress="${want_ingress:-n}"
INGRESS_CHOICE="traefik"
if [[ "${want_ingress,,}" =~ ^(y|yes)$ ]]; then
  echo "Choose ingress controller:"
  echo "  1) Traefik (k3s built-in)"
  echo "  2) ingress-nginx"
  read -r -p "Enter choice [1]: " choice
  choice="${choice:-1}"
  if [ "$choice" = "2" ]; then
    INGRESS_CHOICE="ingress-nginx"
  fi
fi

# Prepare k3s install flags
INSTALL_FLAGS="--write-kubeconfig-mode 644"
if [[ "${want_ingress,,}" =~ ^(y|yes)$ ]] && [ "$INGRESS_CHOICE" = "ingress-nginx" ]; then
  INSTALL_FLAGS="--disable traefik ${INSTALL_FLAGS}"
fi

echo "Installing k3s..."
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="${INSTALL_FLAGS}" sh -s -

# Helper to run kubectl: prefer 'k3s kubectl' then fallback to kubectl with kubeconfig
run_kubectl() {
  if command -v k3s >/dev/null 2>&1; then
    k3s kubectl "$@"
  elif command -v kubectl >/dev/null 2>&1; then
    kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"
  else
    echo "kubectl not available" >&2
    return 1
  fi
}

echo "Waiting for cluster to be ready..."
for i in $(seq 1 30); do
  if run_kubectl get nodes >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! run_kubectl get nodes >/dev/null 2>&1; then
  echo "Cluster not responding; check k3s service." >&2
  exit 1
fi

# Ingress installation if requested and not present
if [[ "${want_ingress,,}" =~ ^(y|yes)$ ]]; then
  if [ "$INGRESS_CHOICE" = "traefik" ]; then
    echo "Using Traefik (built-in when not disabled). If Traefik was disabled, re-run k3s without --disable traefik or install Traefik via Helm."
  else
    echo "Deploying ingress-nginx..."
    run_kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.7.1/deploy/static/provider/cloud/deploy.yaml
    run_kubectl -n ingress-nginx wait --for=condition=available --timeout=120s deployment/ingress-nginx-controller || true
  fi

  # Detect LoadBalancer external IP for common ingress services
  echo "Checking for LoadBalancer IP on ingress services..."
  sleep 2
  LB_IP=""
  if run_kubectl -n ingress-nginx get svc ingress-nginx-controller >/dev/null 2>&1; then
    LB_IP=$(run_kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  fi
  if [ -z "$LB_IP" ] && run_kubectl -n kube-system get svc traefik >/dev/null 2>&1; then
    LB_IP=$(run_kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  fi

  if [ -z "$LB_IP" ]; then
    read -r -p "No external LoadBalancer IP detected. Install MetalLB to provide LoadBalancer functionality? [y/N] " want_metallb
    want_metallb="${want_metallb:-n}"
    if [[ "${want_metallb,,}" =~ ^(y|yes)$ ]]; then
      echo "Installing MetalLB (layer2)..."
      run_kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml
      echo "Enter a CIDR or IP range for MetalLB addresses (example: 192.168.0.240-192.168.0.250):"
      read -r -p "IP pool: " ip_pool
      ip_pool="${ip_pool:-}"
      if [ -n "$ip_pool" ]; then
        cat <<EOF | run_kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${ip_pool}
EOF
        echo "MetalLB configured with pool: $ip_pool"
      else
        echo "No IP pool provided; MetalLB deployed but not configured."
      fi
    else
      echo "Skipping MetalLB installation. Ingress may expose via NodePort or hostPort without a LoadBalancer."
    fi
  else
    echo "Detected LoadBalancer IP: $LB_IP"
  fi
fi

echo ""
echo "Verification (brief):"
run_kubectl get nodes || true
run_kubectl get pods -A --no-headers | sed -n '1,15p' || true
if [[ "${want_ingress,,}" =~ ^(y|yes)$ ]]; then
  echo "Ingress services:"
  run_kubectl -n ingress-nginx get svc 2>/dev/null || run_kubectl -n kube-system get svc | sed -n '1,20p' || true
fi

echo ""
echo "k3s installation finished. kubeconfig: /etc/rancher/k3s/k3s.yaml"
echo "Hint: to use kubectl as ${USER_NAME}: sudo -u ${USER_NAME} KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes"
