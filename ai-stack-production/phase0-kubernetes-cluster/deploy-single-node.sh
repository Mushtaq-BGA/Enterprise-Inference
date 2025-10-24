#!/bin/bash
# Phase 0: Deploy Single-Node Kubernetes Cluster with Kubespray
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBESPRAY_DIR="$PROJECT_ROOT/kubespray"

echo "========================================="
echo "Phase 0: Kubernetes Single-Node Setup"
echo "========================================="
echo ""

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Check prerequisites
print_info "Checking prerequisites..."

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    print_error "This script requires sudo access. Please run with sudo or configure passwordless sudo."
    exit 1
fi
print_success "Sudo access confirmed"

# Check Python
if ! command -v python3 &> /dev/null; then
    print_error "Python 3 not found. Installing..."
    sudo apt-get update
    sudo apt-get install -y python3 python3-pip
fi
print_success "Python 3 found"

# Check if Kubernetes is already installed
if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null; then
    print_info "Kubernetes cluster already exists!"
    kubectl get nodes
    echo ""
    read -p "Do you want to reinstall? This will destroy the existing cluster. (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Using existing cluster. Skipping to verification..."
        exec "$SCRIPT_DIR/verify-cluster.sh"
        exit 0
    fi
fi

# Get node IP
NODE_IP=$(hostname -I | awk '{print $1}')
print_info "Node IP detected: $NODE_IP"

# Install dependencies
print_info "Installing dependencies..."
sudo apt-get update
sudo apt-get install -y git python3 python3-pip python3-venv sshpass

# Clone Kubespray if not exists
if [ ! -d "$KUBESPRAY_DIR" ]; then
    print_info "Cloning Kubespray into project root..."
    cd "$PROJECT_ROOT"
    git clone https://github.com/kubernetes-sigs/kubespray.git "$(basename "$KUBESPRAY_DIR")"
    cd "$KUBESPRAY_DIR"
    git checkout v2.28.1  # Kubespray v2.28.1 for Kubernetes v1.32.8
else
    print_info "Kubespray already cloned at $KUBESPRAY_DIR"
    cd "$KUBESPRAY_DIR"
fi

# Create Python virtual environment (required for Ubuntu 24.04+)
VENV_DIR="$KUBESPRAY_DIR/.kubespray-venv"
if [ ! -d "$VENV_DIR" ]; then
    print_info "Creating Python virtual environment..."
    python3 -m venv "$VENV_DIR"
    print_success "Virtual environment created"
else
    print_info "Using existing virtual environment"
fi

# Activate virtual environment
print_info "Activating virtual environment..."
source "$VENV_DIR/bin/activate"

# Install Python requirements
print_info "Installing Python requirements in venv..."
pip install --upgrade pip
pip install -r requirements.txt

# Create inventory for single node
print_info "Creating single-node inventory..."
mkdir -p inventory/singlenode

cat > inventory/singlenode/hosts.yaml <<EOF
all:
  hosts:
    node1:
      ansible_host: 127.0.0.1
      ansible_connection: local
      ip: $NODE_IP
      access_ip: $NODE_IP
  children:
    kube_control_plane:
      hosts:
        node1:
    kube_node:
      hosts:
        node1:
    etcd:
      hosts:
        node1:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    calico_rr:
      hosts: {}
EOF

print_success "Inventory created"

# Configure cluster settings
print_info "Configuring cluster settings..."
mkdir -p inventory/singlenode/group_vars

cat > inventory/singlenode/group_vars/all.yml <<EOF
# Cluster configuration
ansible_user: $(whoami)
ansible_become: true
ansible_become_user: root

# Download settings
download_run_once: true
download_localhost: true
EOF

cat > inventory/singlenode/group_vars/k8s_cluster.yml <<EOF
# Kubernetes cluster name
cluster_name: ai-stack-cluster

# Kubernetes version: rely on Kubespray defaults (auto-select based on checksums)

# Container runtime
container_manager: containerd

# Network plugin
kube_network_plugin: calico
kube_network_plugin_multus: false

# DNS
dns_mode: coredns
enable_nodelocaldns: false

# Service CIDR
kube_service_addresses: 10.233.0.0/18

# Pod CIDR
kube_pods_subnet: 10.233.64.0/18

# Proxy mode
kube_proxy_mode: ipvs

# Enable metrics
metrics_server_enabled: true

# Storage
local_path_provisioner_enabled: true
local_path_provisioner_is_default_storageclass: true

# Single node hostname override (must be a string, not boolean, to avoid SAN templating issues)
kube_override_hostname: node1

# Disable HA for single node
etcd_deployment_type: host
etcd_events_cluster_enabled: false

# Allow pods on control plane (handled implicitly without altering SAN list)
EOF

print_success "Configuration complete"

# Deploy cluster
print_info "Deploying Kubernetes cluster (this takes 10-15 minutes)..."
print_info "Follow progress in another terminal: tail -f /tmp/kubespray-install.log"

ansible-playbook -i inventory/singlenode/hosts.yaml \
  --become --become-user=root \
  cluster.yml 2>&1 | tee /tmp/kubespray-install.log

# Configure kubectl
print_info "Configuring kubectl..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config 2>/dev/null || true
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Wait for cluster to be ready
print_info "Waiting for cluster to be ready..."
sleep 30

# Verify installation
print_info "Verifying installation..."
kubectl cluster-info
kubectl get nodes

# Wait for all system pods
print_info "Waiting for system pods to be ready..."
kubectl wait --for=condition=ready pod --all -n kube-system --timeout=600s || true

# Verify metrics-server
print_info "Verifying metrics-server..."
for i in {1..30}; do
    if kubectl top nodes &> /dev/null; then
        print_success "Metrics-server is working"
        break
    fi
    echo -n "."
    sleep 10
done

# Ensure local-path storage class is marked as default if not already
if ! kubectl get storageclass 2>/dev/null | grep -q '(default)'; then
    print_info "Annotating local-path storageclass as default"
    kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite || true
fi

# Summary
echo ""
echo "========================================="
echo "Phase 0 Deployment Summary"
echo "========================================="
print_success "✓ Kubernetes cluster installed"
print_success "✓ Container runtime: containerd"
print_success "✓ Network plugin: Calico"
print_success "✓ DNS: CoreDNS"
print_success "✓ Storage: local-path-provisioner (default)"
print_success "✓ Metrics: metrics-server"
print_success "✓ kubectl configured"
echo ""

# Show cluster info
print_info "Cluster Information:"
kubectl version --short 2>/dev/null || kubectl version
echo ""
kubectl get nodes -o wide
echo ""
kubectl get pods --all-namespaces

echo ""
print_info "Run verification script to ensure everything is working:"
echo "  ./verify-cluster.sh"
echo ""
print_info "Next Step: Deploy Istio and AI Stack components"
echo "  cd ../phase1-cluster-istio && ./deploy-phase1.sh"
echo ""
